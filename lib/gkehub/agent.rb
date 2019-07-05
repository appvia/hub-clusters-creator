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
    def schema
      @schema ||= YAML.safe_load(File.read(File.join(File.dirname(__FILE__), 'schema.yaml')))
    end

    # validate_cluster_options is responsible for validating the options for cluster creation
    # rubocop:disable MetricsMetrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    def validate_cluster_options(config)
      raise ArgumentError, 'you must specify a cluster description' unless config[:description]
      raise ArgumentError, 'you must specify a cluster name' unless config[:name]
      raise ArgumentError, 'you must specify a domain to use' unless config[:domain]
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
    # rubocop:enable MetricsMetrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity

    # provision_gke is responsible for building the infrastructure
    # rubocop:disable MetricsMetrics/AbcSize
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
      cluster
    end
    # rubocop:enable MetricsMetrics/AbcSize

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
      kube.wait(BOOTSTRAP_NAME, BOOTSTRAP_NAMESPACE, 'jobs', version: 'batch/v1', interval: 10) do |x|
        x.status.nil? || x.status['succeeded'] <= 0 ? false : true
      end

      info 'attempting to add or update dns record for grafana'
      name = 'pining-mastiff-grafana'
      namespace = 'loki'

      # @step: wait for the ingress to appaar and provision and grab the address
      kube.wait(name, namespace, 'ingresses', version: 'extensions/v1beta1') do |x|
        x.status.loadBalancer.ingress.empty? ? false : true
      end
      ingress = kube.get(name, namespace, 'ingresses', version: 'extensions/v1beta1')
      address = ingress.status.loadBalancer.ingress.first.ip

      # @step: update the dns record for the ingress
      info "adding a dns record for #{config[:grafana_hostname]} => #{address}"
      compute.dns('grafana', address, config[:domain])
    end
    # rubocop:enable Metrics/AbcSize

    # provision is responsible for provisioning the cluster
    # rubocop:disable Lint/RescueException,Metrics/AbcSize
    def provision(options)
      name = options[:name]

      # @step: validate the options
      info "validating the configurable options for the cluster: '#{name}'"
      config = validate_cluster_options(defaults.merge(options))

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
          cluster_cidr: cluster.ip_allocation_policy.cluster_ipv4_cidr_block,
          endpoint: "https://#{cluster.endpoint}",
          locations: cluster.locations,
          network: config[:network],
          service_cidr: cluster.ip_allocation_policy.services_ipv4_cidr_block,
          token: k.account('sysadmin')
        },
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
            loki/loki-stack,loki,--values /config/bundles/grafana.yaml
            stable/prometheus,kube-system,
          repositories: |
            loki,https://grafana.github.io/loki/charts
          grafana.yaml: |
            loki:
              enabled: true
            promtail:
              enabled: true
            grafana:
              enabled: true
              replicas: 1
              sidecar:
                datasources:
                  enabled: true
              service:
                type: NodePort
                port: 80
                targetPort: 3000
              ingress:
                enabled: true
                path: /*
                hosts:
                  - <%= context[:grafana_hostname] %>
              persistence:
                enabled: true
                accessModes:
                  - ReadWriteOnce
                size: <%= context[:grafana_disk_size] || '10Gi' %>
              grafana.ini:
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
                <%- if context[:github_client_id] -%>
                auth.github:
                  allow_sign_up: true
                  allowed_organizations: %<= context[:github_organization] %>
                  api_url: https://api.github.com/user
                  auth_url: https://github.com/login/oauth/authorize
                  client_id: <%= context[:github_client_id] %>
                  client_secret: <%= config[:github_client_secret] %>
                  enabled: true
                  scopes: user,read:org
                  token_url: https://github.com/login/oauth/access_token
                <%- end -%>
            prometheus:
              enabled: <%= context[:enable_grafana_prometheus] || 'true' %>
              server:
                fullnameOverride: prometheus-server
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
