# frozen_string_literal: true

# Copyright (C) 2019  Rohith Jayawardene <gambol99@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'cluster'
require 'errors'
require 'gke'
require 'json'
require 'kube'
require 'logging'
require 'policies'
require 'template'
require 'json-schema'

module GKE
  # Agent is the main agent class
  # rubocop:disable Metrics/ClassLength,Metrics/MethodLength,Metrics/LineLength
  class Agent
    include Cluster
    include Errors
    include Logging
    include Template

    # is the name of the container image
    BOOTSTRAP_IMAGE = 'quay.io/appvia/hub-bootstrap:latest'
    # is the name of the job
    BOOTSTRAP_NAME = 'bootstrap'
    # is the name of the namespace the job lives in
    BOOTSTRAP_NAMESPACE = 'kube-system'

    def initialize(account, project, region, logging)
      @account = account
      @project = project
      @region  = region
      @logging = logging
    end

    def defaults
      unless defined?(@defaults)
        @defaults = {}
        schema['properties'].each do |k, v|
          next if k == 'authorized_master_cidrs'

          @defaults[k.to_sym] = v['default']
        end
        # @TODO find a better way of doing this
        unless @defaults[:authorized_master_cidrs]
          @defaults[:authorized_master_cidrs] = [{ name: 'any', cidr: '0.0.0.0/0' }]
        end
      end
      @defaults
    end

    # compute returns the compute client
    def compute
      @compute ||= GKE::Compute.new(@account, @project, @region)
    end

    # destroy is responsible for deleting a gke cluster
    def destroy(name)
      compute.delete(name)
    end

    # schema returns the json schema defining all the options we support
    def schema(_provider = 'gke')
      @schema ||= YAML.safe_load(File.read(File.join(File.dirname(__FILE__), 'schema.yaml')))
    end

    # validate_cluster_options is responsible for validating the options for cluster creation
    # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    def validate_cluster_options(config)
      begin
        JSON::Validator.validate!(schema.to_json, config)
      rescue JSON::Schema::ValidationError => e
        raise ArgumentError, "invalid configuration: #{e}"
      end
      raise ArgumentError, "domain: #{config[:domain]} does not exist within project" unless compute.domain?(config[:domain])
      raise ArgumentError, 'disk size must be positive' unless config[:disk_size_gb].positive?
      raise ArgumentError, 'invalid maintenance window should be HH:MM' unless config[:maintenance_window] =~ /^[0-9]{2}:[0-9]{2}$/
      raise ArgumentError, 'size must be positive' unless config[:size].positive?

      # @check the networking options
      raise ArgumentError, 'the network does not exist' unless compute.network?(config[:network])
      raise ArgumentError, 'the subnetwork does not exist' unless compute.subnet?(config[:subnetwork], config[:network]) && !config[:create_subnetwork]

      # @check if subnets exist - need to do something more clever
      # and check for overlapping subnety really but i can't find a gem
      network_checks = []
      network_checks.push(config['cluster_ipv4_cidr']) if config['cluster_ipv4_cidr']
      network_checks.push(config['master_ipv4_cidr_block']) if config['master_ipv4_cidr_block']
      network_checks.push(config['services_ipv4_cidr']) if config['services_ipv4_cidr']

      networks = compute.networks
      network_checks.each do |n|
        networks.each { |x| raise ArgumentError, "network: #{n} already exists" if n == x.cidr }
      end

      if config[:enable_private_network] && !config[:master_ipv4_cidr_block]
        raise ArgumentError, 'you must specify a master_ipv4_cidr_block'
      end

      config
    end
    # rubocop:enable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity

    # provision_gke is responsible for building the infrastructure
    # rubocop:disable Metrics/AbcSize
    def provision_gke(config)
      name = config[:name]

      info "checking if the gke cluster: '#{name}' exists"
      if compute.cluster?(name)
        info "skipping the creation of cluster: '#{name}' as it already exists"
      else
        info "cluster: '#{name}' does not exist, creating now"
        compute.create(cluster_spec(config)) do |operation|
          info "waiting for the cluster: '#{name}' to be created, operation: '#{operation.name}'"
          status = compute.hold_for_operation(operation.name)
          unless status.status_message.nil?
            raise ClusterCreationError, "operation: '#{x.operation_type}' failed, error: #{x.status_message}"
          end
        end
      end
      cluster = compute.cluster(name)

      if config[:enable_private_network]
        info 'checking if cloud-nat device has been created'
        compute.router('router') do |x|
          unless x.nats
            x.nats = compute.default_cloud_nat('cloud-nat')
            compute.patch_router('router', x)
          end
        end
      end

      info "provisioning a dns entry for the master api = > #{cluster.endpoint}"
      compute.dns(kubeapi_name(config).to_s, cluster.endpoint, config[:domain])

      cluster
    end
    # rubocop:enable Metrics/AbcSize

    # provision_bootstrap is responsible for setting up the agents and strapper
    # a) pushes in the configuration for the bootstrapper
    # b) rolls out the kubernetes job to bootstrap the cluster
    # c) grabs the services and provisions the dns
    # rubocop:disable Metrics/AbcSize
    def provision_bootstrap(kube, config)
      info 'attempting to bootstrap the cluster configuration'
      kube.kubectl(generate_bootstrap_config(config))
      kube.kubectl(generate_bootstrap_job)

      info 'waiting for the bootstrapper to complete successfully'
      name = BOOTSTRAP_NAME
      namespace = BOOTSTRAP_NAMESPACE

      kube.wait(name, namespace, 'jobs', version: 'batch/v1', interval: 10, timeout: 500) do |x|
        x.status.nil? || x.status['succeeded'] <= 0 ? false : true
      end
      info 'bootstrap has successfully completed'

      info 'attempting to add or update dns record for grafana'
      name = 'loki-grafana'
      namespace = 'loki'

      # @step: wait for the ingress to appaar and provision and grab the address
      kube.wait(name, namespace, 'ingresses', version: 'extensions/v1beta1') do |x|
        x.status.loadBalancer.ingress.empty? ? false : true
      end
      info 'grafana ingress has been provisioned'
      ingress = kube.get(name, namespace, 'ingresses', version: 'extensions/v1beta1')
      address = ingress.status.loadBalancer.ingress.first.ip

      # @step: update the dns record for the ingress
      info "adding a dns record for #{config[:grafana_hostname]} => #{address}"
      compute.dns(config[:grafana_hostname].split('.').first, address, config[:domain])
    end
    # rubocop:enable Metrics/AbcSize

    # provision is responsible for provisioning the cluster
    # rubocop:disable Lint/RescueException,Metrics/AbcSize
    def provision(options)
      name = options[:name]

      # @step: validate the options
      info "validating the configurable options for the cluster: '#{name}'"
      config = validate_cluster_options(defaults.merge(options))
      domain = config[:domain]

      # @step: check if the cluster already exists, else create it
      begin
        cluster = provision_gke(config)
      rescue Exception => e
        raise ClusterCreationError, "failed to build provision cluster, error: #{e}"
      end

      begin
        k = GKE::Kube.new(cluster.endpoint, compute.authorizer.access_token)
        info 'waiting for the master api endpoint to be available'
        k.wait_for_kubeapi

        # @step: if private networking we need to provision a cloud-nat
        if config[:enable_pod_security_polices]
          info 'creating the default psp binding to unpriviledged policy'
          k.kubectl(DEFAULT_PSP_CLUSTER_ROLE)
          k.kubectl(DEFAULT_PSP_CLUSTERROLE_BINDING)
        end

        info 'applying the default cluster admin service account and role'
        k.kubectl(DEFAULT_CLUSTER_ADMIN_ROLE)
        k.kubectl(DEFAULT_CLUSTER_ADMIN_BINDING)

        provision_bootstrap(k, config)
      rescue Exception => e
        raise BootstrapError, "failed to bootstrap cluster: '#{name}', error: #{e}"
      end

      {
        gcp: {
          project: @project,
          region: @region
        },
        cluster: {
          ca: cluster.master_auth.cluster_ca_certificate,
          endpoint: "https://#{cluster.endpoint}",
          dnsname: "https://#{kubeapi_name(config)}.#{domain}",
          locations: cluster.locations,
          token: k.account('sysadmin'),
          type: 'regional'
        },
        config: config,
        grafana: {
          enabled: true,
          hostname: config[:grafana_hostname]
        },
        loki: {
          enabled: true
        }
      }
    end
    # rubocop:enable Lint/RescueException,Metrics/AbcSize

    private

    # kubeapi_name returns the hostname for the kubernetes master api for this config
    def kubeapi_name(config)
      "#{config[:name]}-kubeapi"
    end

    # generate_bootstrap_config returns the helm values for grafana
    def generate_bootstrap_config(options)
      template = <<~YAML
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: #{BOOTSTRAP_NAME}
          namespace: #{BOOTSTRAP_NAMESPACE}
        data:
          charts: |
            loki/loki-stack,loki,--name loki --values /config/bundles/grafana.yaml
            stable/prometheus,kube-system,--name prometheus
          repositories: |
            loki,https://grafana.github.io/loki/charts
          grafana.yaml: |
            loki:
              enabled: true
              networkPolicy:
                enabled: true
            promtail:
              enabled: true
            prometheus:
              enabled: false
              server:
                fullnameOverride: prometheus-server
            grafana:
              adminUser: admin
              <%- unless context[:grafana_password].empty? %>
              adminPassword: <%= context[:grafana_password] %>
              <%- end %>
              enabled: true
              image:
                repository: grafana/grafana
                tag: <%= context[:grafana_version] || 'latest' %>
                pullPolicy: IfNotPresent
              sidecar:
                datasources:
                  enabled: true
              service:
                type: NodePort
                port: 80
                targetPort: 3000
              ingress:
                enabled: true
                path: ''
                hosts:
                  - <%= context[:grafana_hostname] %>
              persistence:
                enabled: true
                accessModes:
                  - ReadWriteOnce
                size: <%= context[:grafana_disk_size] %><%= context[:grafana_disk_size].to_s.end_with?('Gi') ? '' : 'Gi' %>
              grafana.ini:
                server:
                  domain: <%= context[:grafana_hostname] %>
                  root_url: http://<%= context[:grafana_hostname] %>
                paths:
                  data: /var/lib/grafana/data
                  logs: /var/log/grafana
                  plugins: /var/lib/grafana/plugins
                  provisioning: /etc/grafana/provisioning
                analytics:
                  check_for_updates: true
                log:
                  mode: console
                grafana_net:
                  url: https://grafana.net
                <%- unless context[:github_client_id].empty? -%>
                auth.github:
                  allow_sign_up: true
                  <%- unless context[:github_organization].empty? %>
                  allowed_organizations: <%= context[:github_organization] %>
                  <%- end %>
                  api_url: https://api.github.com/user
                  auth_url: https://github.com/login/oauth/authorize
                  client_id: <%= context[:github_client_id] %>
                  client_secret: <%= context[:github_client_secret] %>
                  enabled: true
                  scopes: user,read:org
                  token_url: https://github.com/login/oauth/access_token
                <%- end -%>
      YAML
      Template::Render.new(options).render(template)
    end

    # generate_bootstrap_job is responsible for generating the bootstrap job
    def generate_bootstrap_job
      template = <<-YAML
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: #{BOOTSTRAP_NAME}
          namespace: #{BOOTSTRAP_NAMESPACE}
        spec:
          backoffLimit: 20
          template:
            spec:
              serviceAccountName: sysadmin
              restartPolicy: OnFailure
              containers:
              - name: bootstrap
                image: #{BOOTSTRAP_IMAGE}
                imagePullPolicy: Always
                env:
                - name: CONFIG_DIR
                  value: /config
                volumeMounts:
                - name: bundle
                  mountPath: /config/bundles
              volumes:
              - name: bundle
                configMap:
                  name: #{BOOTSTRAP_NAME}
      YAML
      template
    end
  end
  # rubocop:enable Metrics/ClassLength,Metrics/MethodLength,Metrics/LineLength
end
