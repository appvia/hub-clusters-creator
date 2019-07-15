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

require 'azure_mgmt_resources'

# rubocop:disable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
module Clusters
  module Providers
    # AKS is the AKS provider
    class AKS
      include Azure::Helpers

      def initialize(provider)
        @subscription = provider[:subscription]
        @tenant = provider[:tenant]
        @client_id = provider[:client_id]
        @client_secret = provider[:client_secret]

        provider = MsRestAzure::ApplicationTokenProvider.new(tenant, client, secret)
        credentials = MsRest::TokenCredentials.new(provider)
        @client = Azure::ARM::Resources::ResourceManagementClient.new(credentials)
        @client.subscription_id = @subscription
      end

      # create is responsible for creating the cluster
      # rubocop:disable Metrics/AbcSize
      def create(name, options)
        # @step: validate the user defined options
        validate(options)

        resource_group = options[:resource_group] || name.to_s
        resource_group_location = options[:region]

        # ensure the resource group is created
        params = Azure::ARM::Resources::Models::ResourceGroup.new.tap do |rg|
          rg.location = resource_group_location
        end
        @client.resource_groups.create_or_update(resource_group, params).value!

        # build the deployment from a json file template from parameters
        deployment = Azure::ARM::Resources::Models::Deployment.new
        deployment.properties = Azure::ARM::Resources::Models::DeploymentProperties.new
        deployment.properties.template = JSON.parse(cluster_template(options))
        deployment.properties.mode = Azure::ARM::Resources::Models::DeploymentMode::Incremental

        # build the deployment template parameters from Hash to {key: {value: value}} format
        deploy_params = File.read(File.expand_path(File.join(__dir__, 'parameters.json')))
        deployment.properties.parameters = JSON.parse(deploy_params)['parameters']

        # put the deployment to the resource group
        @client.deployments.create_or_update(resource_group, 'azure-sample', deployment)
      end
      # rubocop:enable Metrics/AbcSize

      # delete is responsible for deleting the cluster via resource group
      def delete(group)
        puts "deleting the group: #{group}"
      end

      private

      # validate is responsible for validating the options
      def validate(options)
        raise ArgumentError, 'no name specified' unless options[:name]
        raise ArgumentError, 'no region specified' unless options[:region]
      end

      # cluster_template is responsible for rendering the template for ARM
      def cluster_template(config)
        template = <<-YAML
          $schema: https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#
          contentVersion: 1.0.0.0
          parameters:
            name:
              defaultValue: <%= config[:name] %>
              type: String
            dns:
              defaultValue: <%= config[:domain] %>
              type: String
            kubernetes_version:
              defaultValue: <%= config[:version] %>
              type: String
            location:
              defaultValue: <%= config[:region] %>
              type: String
            service_principal_clientid:
              type: String
            service_principal_secret:
              type: String
          variables: {}
          resources:
            - type: Microsoft.ContainerService/managedClusters
              name: "[parameters('name')]"
              apiVersion: '2019-06-01'
              location: "[parameters('location')]"
              tags:
                cluster: "[parameters('name')]"
              properties:
                kubernetesVersion: "[parameters('kubernetes_version')]"
                dnsPrefix: "[parameters('dns')]"
                apiServerAuthorizedIPRanges: []
                agentPoolProfiles:
                  - name: compute
                    count: <%= config[:min_node_count]} %>,
                    maxPods: <%= config[:max_pods_per_node] %>,
                    osDiskSizeGB: <%= config[:disk_size_gb] %>,
                    osType: Linux
                    storageProfile: ManagedDisks
                    type: VirtualMachineScaleSets
                    vmSize: <%= config[:machine_type] %>
                servicePrincipalProfile:
                  clientId: "[parameters('service_principal_clientid')]"
                  secret: "[parameters('service_principal_secret')]"
                linuxProfile:
                  adminUsername: azureuser
                  <%- unless config[:ssh_key].empty? %>
                  ssh:
                    publicKeys:
                      - keyData: <%= config[:ssh_key] %>
                  <%- end %>
                addonProfiles: {}
                enableRBAC: true
                enablePodSecurityPolicy: <%= config[:enable_pod_security_policies] %>
                networkProfile:
                  dnsServiceIP: 10.0.0.10
                  dockerBridgeCidr: <%= config[:docker_cidr] || '172.17.0.1/16' %>
                  loadBalancerSku: basic
                  networkPlugin: azure
                  networkPolicy: azure
                  serviceCidr: <%= config[:services_ipv4_cidr] || '10.0.0.0/16' %>
          outputs:
            endpoint:
              type: string
              value: "[reference(parameters('name')).fqdn]"
        YAML
        Template::Render.new(config).render(template)
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
