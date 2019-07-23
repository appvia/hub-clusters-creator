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
#
require 'hub-clusters-creator/template'
require 'hub-clusters-creator/logging'

# rubocop:disable Metrics/MethodLength,Metrics/LineLength
module HubClustersCreator
  module Providers
    # Bootstrap the provider of the bootstrap job
    # rubocop:disable Metrics/ClassLength
    class Bootstrap
      include Logging
      include HubClustersCreator::Utils::Template

      DEFAULT_CLUSTER_ADMIN_ROLE = <<~YAML
        apiVersion: v1
        kind: ServiceAccount
        metadata:
          name: sysadmin
          namespace: kube-system
      YAML

      DEFAULT_CLUSTER_ADMIN_BINDING = <<~YAML
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: cluster:admin
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: cluster-admin
        subjects:
        - kind: ServiceAccount
          name: sysadmin
          namespace: kube-system
      YAML

      # is the name of the container image
      BOOTSTRAP_IMAGE = 'quay.io/appvia/hub-bootstrap:latest'
      # is the name of the job
      BOOTSTRAP_NAME = 'bootstrap'
      # is the name of the namespace the job lives in
      BOOTSTRAP_NAMESPACE = 'kube-system'

      attr_accessor :client, :config, :name

      def initialize(name, client, config)
        @name = name
        @client = client
        @config = config
      end

      # provision_bootstrap is responsible for setting up the agents and strapper
      # a) pushes in the configuration for the bootstrapper
      # b) rolls out the kubernetes job to bootstrap the cluster
      # c) grabs the services and provisions the dns
      # rubocop:disable Metrics/AbcSize
      def bootstrap(image = BOOTSTRAP_IMAGE)
        client.wait_for_kubeapi

        info 'applying the default cluster admin service account and role'
        client.kubectl(DEFAULT_CLUSTER_ADMIN_ROLE)
        client.kubectl(DEFAULT_CLUSTER_ADMIN_BINDING)

        info 'attempting to bootstrap the cluster configuration'
        client.kubectl(generate_bootstrap_config)
        client.kubectl(generate_bootstrap_job(image))

        info 'waiting for the bootstrap to complete successfully'
        name = BOOTSTRAP_NAME
        namespace = BOOTSTRAP_NAMESPACE

        client.wait(name, namespace, 'jobs', version: 'batch/v1', interval: 10, timeout: 500) do |x|
          x.status.nil? || x.status['succeeded'] <= 0 ? false : true
        end
        info 'bootstrap has successfully completed'

        info 'waiting for grafana ingress load balancer to be provisioned'
        # @step: wait for the ingress to appaar and provision and grab the address
        @client.wait('loki-grafana', 'loki', 'ingresses', version: 'extensions/v1beta1') do |x|
          x.status.loadBalancer.ingress.empty? ? false : true
        end
      end
      # rubocop:enable Metrics/AbcSize

      private

      # generate_bootstrap_config returns the helm values for grafana
      def generate_bootstrap_config
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
                nodeExporter:
                  podSecurityPolicy:
                    enabled: true
                networkPolicy:
                  enabled: true
              grafana:
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
                  hosts:
                    - <%= context[:grafana_hostname] %>
                  path: '/*'
                networkPolicy:
                  enabled: true
                persistence:
                  enabled: false
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
                  <%- unless (context[:github_client_id] || '').empty? -%>
                  auth.github:
                    allow_sign_up: true
                    <%- unless (context[:github_organization] || '').empty? %>
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
        HubClustersCreator::Utils::Template::Render.new(config).render(template)
      end

      # generate_bootstrap_job is responsible for generating the bootstrap job
      def generate_bootstrap_job(image)
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
                  image: #{image}
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
    # rubocop:enable Metrics/ClassLength
  end
end
# rubocop:enable Metrics/MethodLength,Metrics/LineLength
