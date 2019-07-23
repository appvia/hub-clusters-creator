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
require 'hub-clusters-creator/providers/aks/helpers'
require 'hub-clusters-creator/providers/bootstrap'
require 'hub-clusters-creator/template'

require 'azure_mgmt_resources'
require 'azure_mgmt_container_service'
require 'azure_mgmt_dns'
require 'uri'

# rubocop:disable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
module HubClustersCreator
  module Providers
    # AKS is the AKS provider
    class AKS
      include ::Azure::Resources::Profiles::Latest::Mgmt
      include ::Azure::Resources::Profiles::Latest::Mgmt::Models
      include ::Azure::ContainerService::Mgmt::V2019_04_01
      include ::Azure::Dns::Mgmt::V2017_10_01
      include Azure::Helpers
      include HubClustersCreator::Utils::Template
      include Errors
      include Logging

      # rubocop:disable Metrics/AbcSize
      def initialize(provider)
        %i[client_id client_secret region subscription tenant].each do |x|
          raise ArgumentError, "you must specify the '#{x}' provider option" unless provider.key?(x)
        end

        @subscription = provider[:subscription]
        @tenant = provider[:tenant]
        @client_id = provider[:client_id]
        @client_secret = provider[:client_secret]
        @region = provider[:region]

        @provider = MsRestAzure::ApplicationTokenProvider.new(@tenant, @client_id, @client_secret)
        @credentials = MsRest::TokenCredentials.new(@provider)

        @containers = ::Azure::ContainerService::Mgmt::V2019_04_01::ContainerServiceClient.new(@credentials)
        @containers.subscription_id = @subscription

        @dns = ::Azure::Dns::Mgmt::V2017_10_01::DnsManagementClient.new(@credentials)
        @dns.subscription_id = @subscription

        options = {
          client_id: @client_id,
          client_secret: @client_secret,
          credentials: @credentials,
          subscription_id: @subscription,
          tenant_id: @tenant
        }

        @client = Client.new(options)
      end
      # rubocop:enable Metrics/AbcSize

      # create is responsible for creating the cluster
      def create(name, config)
        # @step: validate the user defined options
        validate(config)

        # @step: create the infrastructure deployment
        begin
          provision_aks(name, config)
        rescue StandardError => e
          raise InfrastructureError, "failed to provision cluster, error: #{e}"
        end

        # @step: bootstrap the cluster
        begin
          provision_cluster(name, config)
        rescue StandardError => e
          raise InfrastructureError, "failed to bootstrap cluster, error: #{e}"
        end
      end

      # delete is responsible for deleting the cluster via resource group
      def delete(name)
        return unless resource_group?(name)

        info "deleting the resource group: #{name}"
        @client.resource_groups.delete(name, name)
      end

      private

      # provision_aks is responsible for provision the infrastructure
      # rubocop:disable Metrics/AbcSize
      def provision_aks(name, config)
        # @step: define the resource group
        resource_group_name = name

        # @step: check the resource group exists
        if resource_group?(resource_group_name)
          info "skipping the resource group creation: #{resource_group_name}, already exists"
        else
          info "creating the resource group: #{resource_group_name} in azure"
          params = ::Azure::Resources::Mgmt::V2019_05_10::Models::ResourceGroup.new.tap do |x|
            x.location = @region
          end
          # ensure the resource group is created
          @client.resource_groups.create_or_update(resource_group_name, params)

          # wait for the resource group to be created
          wait(max_retries: 20, interval: 10) do
            resource_group?(resource_group_name)
          end
        end

        info "provisioning the azure deployment manifest: '#{name}', resource group: '#{resource_group_name}'"
        # @step: generate the ARM deployments
        template = YAML.safe_load(cluster_template(config))

        # @step: check if a deployment is already underway and wait for completion - which
        # makes it eaisier to rerun quickly
        if deployment?(resource_group_name, name)
          info "deployment: #{name}, resource group: #{resource_group_name} already underway, waiting for completion"
          wait(interval: 30, max_retries: 20) do
            if deployment?(resource_group_name, name)
              d = deployment(resource_group_name, name)
              d.properties.provisioning_state == 'Succeeded'
            end
          end
        end

        # @step: kick off the deployment and cross fingers
        deployment = ::Azure::Resources::Mgmt::V2019_05_10::Models::Deployment.new
        deployment.properties = ::Azure::Resources::Mgmt::V2019_05_10::Models::DeploymentProperties.new
        deployment.properties.template = template
        deployment.properties.mode = ::Azure::Resources::Mgmt::V2019_05_10::Models::DeploymentMode::Incremental

        # put the deployment to the resource group
        @client.deployments.create_or_update_async(resource_group_name, name, deployment)
        # wait for the deployment to finish
        wait(interval: 30, max_retries: 20) do
          if deployment?(resource_group_name, name)
            d = deployment(resource_group_name, name)
            d.properties.provisioning_state == 'Succeeded'
          end
        end
      end
      # rubocop:enable Metrics/AbcSize

      # provision_cluster is responsible for kicking off the initialization
      # rubocop:disable Metrics/AbcSize
      def provision_cluster(name, config)
        resource_group_name = name

        # @step retrieve the kubeconfig - I HATE everything about Azure!!
        packed = @containers.managed_clusters.list_cluster_admin_credentials(resource_group_name, name)
        kc = YAML.safe_load(packed.kubeconfigs.first.value.pack('c*'))

        ca = kc['clusters'].first['cluster']['certificate-authority-data']
        endpoint = URI(kc['clusters'].first['cluster']['server']).hostname

        # @step: provision a kubernetes client for this cluster
        kube = HubClustersCreator::Kube.new(endpoint,
                                  client_certificate: kc['users'].first['user']['client-certificate-data'],
                                  client_key: kc['users'].first['user']['client-key-data'])

        info "waiting for the kubeapi to become available at: #{endpoint}"
        kube.wait_for_kubeapi

        # @step: provision the bootstrap
        info "attempting to bootstrap the cluster: #{name}"
        HubClustersCreator::Providers::Bootstrap.new(name, kube, config).bootstrap

        # @step: update the dns record for the ingress
        unless (config[:grafana_hostname] || '').empty?
          # Get the ingress resource and extract the load balancer ip address
          ingress = @client.get('loki-grafana', 'loki', 'ingresses', version: 'extensions/v1beta1')

          unless ingress.status.loadBalancer.ingress.empty?
            address = ingress.status.loadBalancer.ingress.first.ip
            info "adding a dns record for #{config[:grafana_hostname]} => #{address}"
            dns(hostname(config[:grafana_hostname]), address, config[:domain])
          end
        end

        {
          cluster: {
            ca: ca,
            endpoint: "https://#{endpoint}",
            token: kube.account('sysadmin')
          },
          config: config,
          services: {
            grafana: {
              hostname: config[:grafana_hostname]
            }
          }
        }
      end
      # rubocop:enable Metrics/AbcSize

      # validate is responsible for validating the options
      def validate(options); end

      # cluster_template is responsible for rendering the template for ARM
      def cluster_template(config)
        template = <<~YAML
          '$schema': https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#
          contentVersion: 1.0.0.0
          parameters: {}
          variables: {}
          resources:
            - type: Microsoft.ContainerService/managedClusters
              name: <%= context[:name] %>
              apiVersion: '2019-06-01'
              location: #{@region}
              tags:
                cluster: <%= context[:name] %>
              properties:
                kubernetesVersion: <%= context[:version] %>
                dnsPrefix: <%= context[:name] %>
                addonProfiles:
                  httpapplicationrouting:
                    enabled: true
                    config:
                      HTTPApplicationRoutingZoneName: <%= context[:domain] %>
                agentPoolProfiles:
                  - name: compute
                    count: <%= context[:size] %>
                    maxPods: 110
                    osDiskSizeGB: <%= context[:disk_size_gb] %>
                    osType: Linux
                    storageProfile: ManagedDisks
                    type: VirtualMachineScaleSets
                    vmSize: <%= context[:machine_type] %>
                servicePrincipalProfile:
                  clientId: #{@client_id}
                  secret: #{@client_secret}
                linuxProfile:
                  adminUsername: azureuser
                  <%- unless (context[:ssh_key] || '').empty? -%>
                  ssh:
                    publicKeys:
                      - keyData: <%= context[:ssh_key] %>
                  <%- end -%>
                enableRBAC: true
                enablePodSecurityPolicy: true
                networkProfile:
                  dnsServiceIP: 10.0.0.10
                  dockerBridgeCidr: 172.17.0.1/16
                  loadBalancerSku: basic
                  networkPlugin: azure
                  networkPolicy: azure
                  serviceCidr: <%= context[:services_ipv4_cidr].empty? ? '10.0.0.0/16' : context[:services_ipv4_cidr] %>
        YAML
        HubClustersCreator::Utils::Template::Render.new(config).render(template)
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
