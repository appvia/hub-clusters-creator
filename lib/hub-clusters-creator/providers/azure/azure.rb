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
require 'hub-clusters-creator/providers/azure/helpers'
require 'hub-clusters-creator/providers/bootstrap'
require 'hub-clusters-creator/template'

require 'azure_mgmt_resources'
require 'json'

# rubocop:disable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
module Clusters
  module Providers
    # AKS is the AKS provider
    class AKS
      include ::Azure::Resources::Profiles::Latest::Mgmt
      include ::Azure::Resources::Profiles::Latest::Mgmt::Models
      include Azure::Helpers
      include Clusters::Utils::Template
      include Errors
      include Logging

      def initialize(provider)
        @subscription = provider[:subscription]
        @tenant = provider[:tenant]
        @client_id = provider[:client_id]
        @client_secret = provider[:client_secret]

        @provider = MsRestAzure::ApplicationTokenProvider.new(@tenant, @client_id, @client_secret)
        @credentials = MsRest::TokenCredentials.new(@provider)

        options = {
          tenant_id: @tenant,
          client_id: @client_id,
          client_secret: @client_secret,
          subscription_id: @subscription,
          credentials: @credentials
        }

        @client = Client.new(options)
      end

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
      def delete(group)
        puts "deleting the group: #{group}"
      end

      private

      # provision_aks is responsible for provision the infrastructure
      # rubocop:disable Metrics/AbcSize
      def provision_aks(name, config)
        # @step: define the resource group
        resource_group_name = config[:resource_group] || name.to_s

        # @step: check the resource group exists
        unless resource_group?(config[:resource_group])
          info "creating the resource group: #{resource_group_name} in azure"
          params = ::Azure::Resources::Mgmt::V2019_05_10::Models::ResourceGroup.new.tap do |x|
            x.location = config[:region]
          end
          # ensure the resource group is created
          @client.resource_groups.create_or_update(resource_group_name, params)
        end

        # @step: generate the ARM deployments
        puts cluster_template(config)
        template = YAML.safe_load(cluster_template(config))
        puts template.to_json

        # @step: kick off the deployment and cross fingers
        deployment = ::Azure::Resources::Mgmt::V2019_05_10::Models::Deployment.new
        deployment.properties = ::Azure::Resources::Mgmt::V2019_05_10::Models::DeploymentProperties.new
        deployment.properties.template = template.to_json
        deployment.properties.mode = ::Azure::Resources::Mgmt::V2019_05_10::Models::DeploymentMode::Incremental

        # put the deployment to the resource group
        @client.deployments.create_or_update(resource_group_name, name, deployment)
      end
      # rubocop:enable Metrics/AbcSize

      # provision_cluster is responsible for kicking off the initialization
      def provision_cluster(name, config); end

      # validate is responsible for validating the options
      def validate(options)
        %i[name region machine_type ssh_key].each do |x|
          raise ArgumentError, "you must specify the #{x} options" unless options.key?(x)
        end
      end

      # cluster_template is responsible for rendering the template for ARM
      def cluster_template(config)
        template = <<~YAML
          $schema: https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#
          contentVersion: 1.0.0.0
          parameters: {}
          variables:
            name: '<%= context[:name] %>'
            disk_size: <%= context[:disk_size_gb] %>
            domain: '<%= context[:name] %>'
            location: '<%= context[:region] %>'
            machine_type: '<%= context[:machine_type] %>'
            node_size: <%= context[:size] %>
            services_ipv4_cidr: '<%= context[:services_ipv4_cidr].empty? ? '10.0.0.0/16' : context[:services_ipv4_cidr] %>'
            service_principal_clientid: 'me'
            service_principal_secret: 'me'
            ssh_key: '<%= context[:ssh_key] %>'
            version: '<%= context[:version] %>'
          resources:
            - type: Microsoft.ContainerService/managedClusters
              name: \"[variables(\'name\')]\"
              apiVersion: '2019-06-01'
              location: \"[variables(\'location\')]\"
              tags:
                cluster: \"[variables(\'name\')]\"
              properties:
                kubernetesVersion: \"[variables(\'version\')]\"
                dnsPrefix: \"[variables(\'name\')]\"
                agentPoolProfiles:
                  - name: compute
                    count: \"[variables(\'node_size\')]\"
                    maxPods: 110
                    osDiskSizeGB: \"[variables(\'disk_size\')]\"
                    osType: Linux
                    storageProfile: ManagedDisks
                    type: VirtualMachineScaleSets
                    vmSize: \"[variables(\'machine_type\')]\"
                servicePrincipalProfile:
                  clientId: \"[variables(\'service_principal_clientid\')]\"
                  secret: \"[variables(\'service_principal_secret\')]\"
                linuxProfile:
                  adminUsername: azureuser
                  <%- unless (context[:ssh_key] || '').empty? -%>
                  ssh:
                    publicKeys:
                      - keyData: \"[variables(\'ssh_key\')]\"
                  <%- end -%>
                addonProfiles: {}
                enableRBAC: true
                enablePodSecurityPolicy: true
                networkProfile:
                  dnsServiceIP: 10.0.0.10
                  dockerBridgeCidr: 172.17.0.1/16
                  loadBalancerSku: basic
                  networkPlugin: azure
                  networkPolicy: azure
                  serviceCidr: \"[variables(\'services_ipv4_cidr\')]"
          outputs:
            endpoint:
              type: string
              value: \"[reference(variables(\'name\')).fqdn]\"
        YAML
        Clusters::Utils::Template::Render.new(config).render(template)
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
