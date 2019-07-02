# frozen_string_literal: true

require 'cluster'
require 'gke'
require 'kube'
require 'policies'
require 'template'

module GKE
  # rubocop:disable Metrics/ClassLength,Metrics/MethodLength,Metrics/LineLength
  # Provision is the main agent class
  class Provision
    include Cluster
    include Compute
    include Policies
    include Template

    def initialize(account, project, region)
      @account = account
      @project = project
      @region  = region
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
    def destroy(name, project = @project, region = @region)
      # @step: check the cluster exists
      raise Exception, "the cluster: #{name} does not exist" unless exist?(name)

      gke.delete_project_location_cluster("projects/#{project}/locations/#{region}/clusters/#{name}")
    end

    # provision is responsible for provisioning the cluster
    # rubocop:disable Metrics/AbcSize
    def provision(options = {})
      # @step: validate the options
      raise ArgumentError, 'you must specify a cluster name' unless options[:name]
      raise ArgumentError, 'you must specify a cluster description' unless options[:description]

      name = options[:name]

      # @step: merge the default options with user defined ones
      config = default_options.merge(options)

      # @step: we check if the cluster already exists
      unless exist?(name)
        # @step: attempt to provision the cluster
        path = "projects/#{@project}/locations/#{@region}"
        operation = gke.create_project_location_cluster(path, cluster_spec(config))
        hold_for_operation(operation.name)
      end

      # @step: if private network we need to create a cloud-nat devices if
      # not already there
      edge = router('router')
      if edge.nats.nil?
        edge.nats = default_nat('cloud-nat')
        compute.patch_router(@project, @region, 'router', edge)
      end

      # @step: get the cluster endpoint
      cluster = list_clusters.select { |x| x.name = name }.first

      # @step: wait on the api to become available
      k = GKE::Kube.new(cluster.endpoint, authorize.access_token)
      k.hold_for_kubeapi

      # @step: if private networking we need to provision a cloud-nat
      if config[:enable_pod_security_polices]
        k.kubectl(DEFAULT_PSP_CLUSTER_ROLE)
        k.kubectl(DEFAULT_PSP_CLUSTERROLE_BINDING)
      end

      # @step: apply the default cluster admin
      k.kubectl(DEFAULT_CLUSTER_ADMIN_ROLE)
      k.kubectl(DEFAULT_CLUSTER_ADMIN_BINDING)

      # @step: provision the software bundles
      k.kubectl(bundle_options(config))
      k.kubectl(DEFAULT_BOOTSTRAP_JOB)

      # @step: wait for the bootstrapper to complete
      puts <<~TEXT
        Kubernetes API: https://#{cluster.endpoint}
        GCP Region: #{@region}
        GCP Project: #{@project}
        Certificate Autority: #{cluster.master_auth.cluster_ca_certificate}
        Cluster Token: #{k.service_account('sysadmin')}
        Cloud NAT: #{config[:enable_private_network]}
      TEXT
    end
    # rubocop:enable Metrics/AbcSize

    private

    # bundle_options returns the helm values for grafana
    def bundle_options(options)
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
