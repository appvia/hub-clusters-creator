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
      BOOTSTRAP_IMAGE = 'quay.io/appvia/hub-bootstrap:v0.1.0'

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
      # rubocop:disable Metrics/AbcSize, Style/ConditionalAssignment, Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      def bootstrap(image = BOOTSTRAP_IMAGE)
        client.wait_for_kubeapi

        info 'applying the default cluster admin service account and role'
        client.kubectl(DEFAULT_CLUSTER_ADMIN_SA)
        client.kubectl(DEFAULT_NAMESPACE_AGENT_SA)
        client.kubectl(DEFAULT_CLUSTER_ADMIN_BINDING)

        ## Namespaces
        config[:namespaces] = [
          { name: 'brokers', enable_istio: true },
          { name: 'grafana', enable_istio: true },
          { name: 'logging', enable_istio: false },
          { name: 'prometheus', enable_istio: false }
        ]

        ## Storage Classes
        config[:storage_class] = 'default'
        case config[:provider]
        when 'gke'
          config[:storage_class] = 'standard'
        end

        ## Operators
        config[:operators] = [
          {
            package: 'prometheus',
            channel: 'beta',
            label: 'k8s-app=prometheus-operator',
            namespace: 'prometheus'
          },
          {
            package: 'grafana-operator',
            channel: 'alpha',
            label: 'app=grafana-operator',
            namespace: 'grafana'
          },
          {
            package: 'loki-operator',
            channel: 'stable',
            label: 'name=loki-operator',
            namespace: 'logging'
          },
          {
            package: 'metrics-operator',
            channel: 'stable',
            label: 'name=metrics-operator',
            namespace: 'prometheus'
          },
          {
            package: 'mariadb-operator',
            channel: 'stable',
            label: 'name=mariadb-operator',
            namespace: 'grafana'
          }
        ]

        ## Operatorgroups
        config[:operator_groups] ||= []
        if config[:enable_istio]
          config[:operator_groups].push(
            namespace: 'istio-system'
          )
        end

        ## Grafana
        config[:grafana_password] = has?(config[:grafana_password], random(12))
        config[:grafana_db_password] = has?(config[:grafana_db_password], random(12))

        ## Cloud Service Brokers
        config[:broker_username] = 'root'
        config[:broker_password] = has?(config[:broker_password], random(12))
        config[:broker_db_password] = has?(config[:broker_db_password], random(12))
        config[:broker_db_name] = 'broker'
        if config[:enable_service_broker]
          case config[:provider]
          when 'gke'
            config[:operators].push(
              channel: 'stable',
              label: 'name=gcp-service-broker-operator',
              namespace: 'brokers',
              package: 'gcp-service-broker-operator'
            )
            config[:operators].push(
              package: 'mariadb-operator',
              channel: 'stable',
              label: 'name=mariadb-operator',
              namespace: 'brokers'
            )
          when 'eks'
            config[:operators].push(
              channel: 'stable',
              label: 'name=aws-service-broker-operator',
              namespace: 'brokers',
              package: 'aws-service-broker-operator'
            )
          end
        end

        ## Istio Related
        config[:kiali_password] = has?(config[:kiali_password], random(12))

        if config[:enable_istio]
          config[:enable_kiali] = true
          config[:operators].push(
            catalog: 'operatorhubio-catalog',
            channel: 'stable',
            label: 'app=kiali-operator',
            namespace: 'istio-system',
            package: 'kiali'
          )
        end

        info 'attempting to bootstrap the cluster configuration'
        client.kubectl(generate_bootstrap_config)
        client.kubectl(generate_bootstrap_olm_config)
        client.kubectl(generate_bootstrap_job(image))

        info 'waiting for the bootstrap to complete successfully'
        client.wait('bootstrap', 'kube-system', 'jobs', version: 'batch/v1') do |x|
          (x.status['succeeded'] || 0).positive?
        end

        # @step: extract the grafana api
        grafana_key_name = 'grafana-api-key'
        unless client.exists?(grafana_key_name, 'kube-system', 'secrets')
          raise StandardError, 'grafana api secret is missing'
        end

        grafana_api_key = Base64.decode64(client.get(grafana_key_name, 'kube-system', 'secrets').data.key)

        info 'bootstrap has successfully completed'
        name = 'grafana-service'

        # @step: grab the loki service
        svc = client.get(name, 'grafana', 'services')
        case svc.spec.type
        when 'NodePort'
          resource_type = 'ingresses'
          resource_version = 'extensions/v1beta1'
        else
          resource_type = 'services'
          resource_version = 'v1'
        end

        info 'waiting for grafana service load balancer to be provisioned'
        resource = client.wait('grafana-ingress', 'grafana', resource_type, version: resource_version) do |x|
          x.status.loadBalancer.ingress.empty? ? false : true
        end

        # retrieve the hostname or address of the loadbalancer
        host = resource.status.loadBalancer.ingress.first
        case svc.spec.type
        when 'NodePort'
          host = host.ip
        else
          host = host.hostname
        end

        ## the result
        result = {
          catalog: {
            enabled: config[:enable_service_broker],
            namespace: 'catalog'
          },
          grafana: {
            address: host,
            api_key: grafana_api_key,
            namespace: 'grafana',
            password: config[:grafana_password],
            url: "http://#{config[:grafana_hostname]}.#{config[:domain]}"
          },
          loki: {
            enabled: true,
            namespace: 'logging',
            url: 'http://loki.logging.svc.cluster.local:3100'
          },
          prometheus: {
            enabled: true,
            namespace: 'prometheus',
            url: 'http://prometheus.prometheus.svc.cluster.local:9090'
          }
        }
        if config[:enable_service_broker]
          result[:broker] = {
            enabled: true,
            namespace: 'brokers',
            provider: config[:provider]
          }
        end

        if config[:enable_istio]
          result[:istio] = {
            enabled: true,
            namespace: 'istio-system'
          }
          result[:kiali] = {
            enabled: true,
            password: config[:kiali_password],
            url: 'http://kiali.istio-system.svc.cluster.local:20001'
          }
        end

        result
      end
      # rubocop:enable Metrics/AbcSize, Style/ConditionalAssignment, Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity

      private

      def has?(value, default_value)
        return default_value if value.nil? || value.empty?

        value
      end

      def random(length = 12)
        (0...length).map { chars[rand(chars.length)] }.join
      end

      def chars
        @chars ||= [('a'..'z'), ('A'..'Z')].map(&:to_a).flatten
      end

      # generate_bootstrap_config charts and repos
      def generate_bootstrap_config
        HubClustersCreator::Utils::Template::Render
          .new(config)
          .render(File.read("#{__dir__}/bootstrap.yaml.erb"))
      end

      # generate_bootstrap_olm_config returns the manifests
      def generate_bootstrap_olm_config
        HubClustersCreator::Utils::Template::Render
          .new(config)
          .render(File.read("#{__dir__}/bootstrap-olm.yaml.erb"))
      end

      # generate_bootstrap_job is responsible for generating the bootstrap job
      def generate_bootstrap_job(image)
        config[:bootstrap_image] = image
        HubClustersCreator::Utils::Template::Render
          .new(config)
          .render(File.read("#{__dir__}/bootstrap-job.yaml.erb"))
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
