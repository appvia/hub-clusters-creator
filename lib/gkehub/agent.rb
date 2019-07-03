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
require 'gke'
require 'kube'
require 'logging'
require 'policies'
require 'template'

module GKE
  # rubocop:disable Metrics/ClassLength,Metrics/MethodLength,Metrics/LineLength
  # Provision is the main agent class
  class Provision
    include Cluster
    include Logging
    include Template

    attr_accessor :compute

    def initialize(account, project, region, logging)
      @account = account
      @project = project
      @region  = region
      @compute = GKE::Compute.new(@account, @project, @region)
      @logging = logging
    end

    # defaults are the default options for a cluster
    def defaults
      {
        authorized_master_cidrs: [{ name: 'any', cidr: '0.0.0.0/0' }],
        cluster_ipv4_cidr: '',
        create_subnetwork: false,
        disk_size_gb: 100,
        enable_autorepair: true,
        enable_autoscaler: true,
        enable_autoupgrade: true,
        enable_binary_authorization: false,
        enable_horizontal_pod_autoscaler: false,
        enable_http_loadbalancer: true,
        enable_istio: false,
        enable_logging: true,
        enable_monitoring: true,
        enable_network_polices: true,
        enable_pod_security_polices: true,
        enable_private_endpoint: false,
        enable_private_network: true,
        image_type: 'COS',
        machine_type: 'n1-standard-1',
        maintenance_window: '03:00',
        master_ipv4_cidr_block: '172.16.0.0/28',
        max_nodes: 10,
        network: 'default',
        preemptible: false,
        region: 'europe-west2',
        services_ipv4_cidr: '',
        size: 1,
        subnetwork: 'default',
        version: 'latest'
      }.freeze
    end

    # destroy is responsible for deleting a gke cluster
    def destroy(name)
      compute.delete(name)
    end

    # validate_cluster_options is responsible for validating the options for cluster creation
    # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    def validate_cluster_options(config)
      raise ArgumentError, 'you must specify a cluster description' unless config[:description]
      raise ArgumentError, 'you must specify a cluster name' unless config[:name]
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
            raise ClusterCreationError, "operation: #{x.operation_type} failed, error: #{x.status_message}"
          end
        end
      end
      cluster = compute.cluster(name)

      if config[:enable_private_network]
        info 'checking if cloud-nat device has been created'
        compute.router('router') do |x|
          unless x.nats
            x.nats = compute.default_nat('cloud-nat')
            compute.patch_router('router', x)
          end
        end
      end
      yield cluster if block_given?

      cluster
    end
    # rubocop:enable Metrics/AbcSize

    # provision is responsible for provisioning the cluster
    # rubocop:disable Metrics/AbcSize,Metrics/BlockLength
    def provision(options = {})
      name = options[:name]

      # @step: validate the options
      info "validating the configurable options for the cluster: '#{name}'"
      config = validate_cluster_options(defaults.merge(options))
      result = {}

      # @step: check if the cluster already exists, else create it
      provision_gke(config) do |cluster|
        # @step: if private networkng, create a cloud-nat devices if not already there
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

          info 'applying the cluster bootstrap job'
          k.kubectl(bootstrap_config(config))
          k.kubectl(DEFAULT_BOOTSTRAP_JOB)

          info 'waiting for the bootstrap job to complete'
          k.wait_for_job('bootstrap', 'kube-system')

          info 'successfully bootstrapped the cluster'
        rescue StandardError => e
          raise BootstrapError, "failed to bootstrap cluster: '#{name}', error: #{e}"
        end

        result = {
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
            enabled: true
          },
          loki: {
            enabled: true
          }
        }
      end
      result
    end
    # rubocop:enable Metrics/AbcSize,Metrics/BlockLength

    private

    # bootstrap_config returns the helm values for grafana
    def bootstrap_config(options)
      template = <<~YAML
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: bootstrap-bundle
          namespace: kube-system
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
              enabled: false
              sidecar:
                datasources:
                  enabled: true
              <%- if context[:grafana_ingress] -%>
              service:
                type: NodePort
                port: 80
                targetPort: 3000
              ingress:
                enabled: true
                path: /
                hosts:
                - <%= context[:grafana_hostname] %>
              <%- end -%>
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
              enabled: false
              server:
                fullnameOverride: prometheus-server
      YAML
      Template::Render.new(options).render(template)
    end
  end
  # rubocop:enable Metrics/ClassLength,Metrics/MethodLength,Metrics/LineLength
end
