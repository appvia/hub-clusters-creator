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

    def initialize(account, project, region)
      @account = account
      @project = project
      @region  = region
      @compute = GKE::Compute.new(@account, @project, @region)
    end

    # default_options are the default options for a cluster
    def default_options
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
        logging: false,
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

    # provision is responsible for provisioning the cluster
    # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    def provision(options = {})
      raise ArgumentError, 'you must specify a cluster name' unless options[:name]
      raise ArgumentError, 'you must specify a cluster description' unless options[:description]

      name = options[:name]
      config = default_options.merge(options)
      @logging = options[:logging]

      # @step: we check if the cluster already exists
      if !compute.cluster?(name)
        info "creating the cluster: #{name}, region: #{@region}"
        operation = compute.create(cluster_spec(config))
        info "waiting for the cluster: #{name} to be created"
        compute.hold_for_operation(operation.name)
      else
        info "skipping the creation of cluster: #{name} as it already exists"
      end
      cluster = compute.cluster(name)

      # @step: if private networkng, create a cloud-nat devices if not already there
      if config[:enable_private_network]
        info 'checking if cloud-nat device has been created'
        edge = compute.router('router')
        if edge.nats.nil?
          edge.nats = compute.default_nat('cloud-nat')
          compute.patch_router('router', edge)
        end
      end

      # @step: wait on the api to become available
      k = GKE::Kube.new(cluster.endpoint, compute.authorizer.access_token)
      k.wait

      # @step: if private networking we need to provision a cloud-nat
      if config[:enable_pod_security_polices]
        k.kubectl(DEFAULT_PSP_CLUSTER_ROLE)
        k.kubectl(DEFAULT_PSP_CLUSTERROLE_BINDING)
      end

      # @step: apply the default cluster admin
      k.kubectl(DEFAULT_CLUSTER_ADMIN_ROLE)
      k.kubectl(DEFAULT_CLUSTER_ADMIN_BINDING)

      # @step: provision the software bundles
      k.kubectl(bootstrap_config(config))
      k.kubectl(DEFAULT_BOOTSTRAP_JOB)

      # @step: wait for the bootstrapper to complete
      puts <<~TEXT
        Kubernetes API: https://#{cluster.endpoint}
        GCP Region: #{@region}
        GCP Project: #{@project}
        Certificate Autority: #{cluster.master_auth.cluster_ca_certificate}
        Cluster Token: #{k.account('sysadmin')}
        Cloud NAT: #{config[:enable_private_network]}
      TEXT
    end
    # rubocop:enable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity

    private

    # bootstrap_config returns the helm values for grafana
    def bootstrap_config(options)
      template = <<~YAML
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: hub-bootstrap-bundle
          namespace: kube-system
        data:
          charts: |
            loki/loki-stack,loki,-f /config/bundles/grafana.yaml
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
              <% if context[:grafana_ingress] %>
              service:
                type: NodePort
                port: 80
                targetPort: 3000
                annotations: {}
                labels: {}

              ingress:
                enabled: true
                path: /
                hosts:
                  - <%= context[:grafana_hostname] %>
              <% end %>
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
                <% if context[:github_client_id] %>
                auth.github:
                  client_id: <%= context[:github_client_id] %>
                  client_secret: <%= config[:github_client_secret] %>
                  enabled: true
                  allow_sign_up: true
                  scopes: user,read:org
                  auth_url: https://github.com/login/oauth/authorize
                  token_url: https://github.com/login/oauth/access_token
                  api_url: https://api.github.com/user
                  allowed_organizations: %<= context[:github_organization] %>
                <% end %>
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
