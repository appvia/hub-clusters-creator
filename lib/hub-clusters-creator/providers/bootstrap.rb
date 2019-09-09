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

require 'base64'

# rubocop:disable Metrics/MethodLength,Metrics/LineLength
module HubClustersCreator
  # Providers is the namespace of the cloud providers
  module Providers
    # Bootstrap the provider of the bootstrap job
    # rubocop:disable Metrics/ClassLength
    class Bootstrap
      include Logging
      include HubClustersCreator::Utils::Template

      DEFAULT_CLUSTER_ADMIN_SA = <<~YAML
        apiVersion: v1
        kind: ServiceAccount
        metadata:
          name: sysadmin
          namespace: kube-system
      YAML

      DEFAULT_NAMESPACE_AGENT_SA = <<~YAML
        apiVersion: v1
        kind: ServiceAccount
        metadata:
          name: robot
          namespace: default
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
          name: robot
          namespace: default
        - kind: ServiceAccount
          name: sysadmin
          namespace: kube-system
      YAML

      # is the name of the container image
      BOOTSTRAP_IMAGE = 'quay.io/appvia/hub-bootstrap:v0.0.9'

      attr_accessor :client, :config, :name

      def initialize(name, provider, client, config)
        @name = name
        @client = client
        @config = config
        @provider = provider
        @config[:provider] = @provider
      end

      # provision_bootstrap is responsible for setting up the agents and strapper
      # a) pushes in the configuration for the bootstrapper
      # b) rolls out the kubernetes job to bootstrap the cluster
      # c) grabs the services and provisions the dns
      # rubocop:disable Metrics/AbcSize, Style/ConditionalAssignment
      def bootstrap(image = BOOTSTRAP_IMAGE)
        client.wait_for_kubeapi

        info 'applying the default cluster admin service account and role'
        client.kubectl(DEFAULT_CLUSTER_ADMIN_SA)
        client.kubectl(DEFAULT_NAMESPACE_AGENT_SA)
        client.kubectl(DEFAULT_CLUSTER_ADMIN_BINDING)

        # @step: check if there is a password for grafana and if not create on
        if config[:grafana_password].empty?
          chars = [('a'..'z'), ('A'..'Z')].map(&:to_a).flatten
          config[:grafana_password] = (0...12).map { chars[rand(chars.length)] }.join
        end

        info 'attempting to bootstrap the cluster configuration'
        client.kubectl(generate_bootstrap_config)
        client.kubectl(generate_bootstrap_job(image))

        info 'waiting for the bootstrap to complete successfully'
        client.wait('bootstrap', 'kube-system', 'jobs', version: 'batch/v1') do |x|
          x.status['succeeded'].positive?
        end

        # @step: extract the grafana api
        grafana_key_name = 'grafana-api-key'
        unless client.exists?(grafana_key_name, 'kube-system', 'secrets')
          raise StandardError, 'grafana api secret is missing'
        end

        grafana_api_key = Base64.decode64(client.get(grafana_key_name, 'kube-system', 'secrets').data.key)

        info 'bootstrap has successfully completed'
        name = 'loki-grafana'
        namespace = 'metrics'

        # @step: grab the loki service
        svc = client.get(name, namespace, 'services')
        case svc.spec.type
        when 'NodePort'
          resource_type = 'ingresses'
          resource_version = 'extensions/v1beta1'
        else
          resource_type = 'services'
          resource_version = 'v1'
        end

        info 'waiting for grafana service load balancer to be provisioned'
        resource = client.wait(name, namespace, resource_type, version: resource_version) do |x|
          x.status.loadBalancer.ingress.empty? ? false : true
        end
        host = resource.status.loadBalancer.ingress.first
        case svc.spec.type
        when 'NodePort'
          host = host.ip
        else
          host = host.hostname
        end
        {
          grafana: {
            hostname: host,
            key: grafana_api_key,
            password: @config[:grafana_password]
          }
        }
      end
      # rubocop:enable Metrics/AbcSize, Style/ConditionalAssignment

      private

      # generate_bootstrap_config returns the helm values for grafana
      def generate_bootstrap_config
        template = File.read("#{__dir__}/bootstrap.erb.yaml")
        HubClustersCreator::Utils::Template::Render.new(config).render(template)
      end

      # generate_bootstrap_job is responsible for generating the bootstrap job
      def generate_bootstrap_job(image)
        template = <<-YAML
          apiVersion: batch/v1
          kind: Job
          metadata:
            name: bootstrap
            namespace: kube-system
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
                  - name: PROVIDER
                    value: #{@provider}
                  - name: GRAFANA_NAMESPACE
                    value: metrics
                  - name: GRAFANA_HOSTNAME
                    value: loki-grafana
                  - name: GRAFANA_PASSWORD
                    value: #{@config[:grafana_password]}
                  - name: GRAFANA_API_SECRET
                    value: grafana-api-key
                  - name: GRAFANA_API_SECRET_NAMESPACE
                    value: kube-system
                  - name: GRAFANA_SCHEMA
                    value: http
                  - name: OLM_VERSION
                    value: '#{@config[:olm_version]}'
                  volumeMounts:
                  - name: bundle
                    mountPath: /config/bundles
                volumes:
                - name: bundle
                  configMap:
                    name: bootstrap
        YAML
        template
      end
    end
    # rubocop:enable Metrics/ClassLength

    private

    # validate is responsible for validating the options
    # rubocop:disable Style/GuardClause
    def validate(config)
      if config[:github_client_id] && config[:github_client_secret].nil?
        raise ArgumentError, 'you have specifed the github client id but not the secret'
      end
      if config[:github_client_secret] && config[:github_client_id].nil?
        raise ArgumentError, 'you have specifed the github client secret but not the client id'
      end
    end
    # rubocop:enable Style/GuardClause
  end
end
# rubocop:enable Metrics/MethodLength,Metrics/LineLength
