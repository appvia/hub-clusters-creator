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
require 'json'
require 'json_schema'

require 'hub-clusters-creator/errors'
require 'hub-clusters-creator/logging'
require 'hub-clusters-creator/providers/aks/azure.rb'
require 'hub-clusters-creator/providers/gke/gke.rb'

# rubocop:disable Metrics/MethodLength,Metrics/LineLength
module HubClustersCreator
  # Agent is the main agent class
  class Agent
    include Errors
    include Logging

    # rubocop:disable Metrics/AbcSize
    def initialize(provider)
      @provider_name = provider[:provider]

      # @step: validate the provider configuration
      JsonSchema.parse!(HubClustersCreator::Agent.provider_schema(@provider_name)).validate(provider)

      # @step: create and return a provider instance
      case @provider_name
      when 'gke'
        @provider = HubClustersCreator::Providers::GKE.new(
          account: provider[:account],
          project: provider[:project],
          region: provider[:region]
        )
      when 'aks'
        @provider = HubClustersCreator::Providers::AKS.new(
          client_id: provider[:client_id],
          client_secret: provider[:client_secret],
          region: provider[:region],
          subscription: provider[:subscription],
          tenant: provider[:tenant]
        )
      else
        raise ArgumentError, "cloud provider: #{@provider_name} not supported"
      end
    end
    # rubocop:enable Metrics/AbcSize

    # defaults builds the default from the schema
    def defaults(name)
      values = {}
      HubClustersCreator::Agent.schema(name)['properties'].reject { |x, _v| x == 'authorized_master_cidrs' }.each do |k, v|
        values[k.to_sym] = v['default']
      end
      # @TODO find a better way of doing this
      unless values[:authorized_master_cidrs]
        values[:authorized_master_cidrs] = [{ name: 'any', cidr: '0.0.0.0/0' }]
      end
      values
    end

    # providers provides a list of providers
    def self.providers
      HubClustersCreator::Agent.providers_schema['providers'].keys
    end

    # config returns the provider configuration
    def self.config(name)
      HubClustersCreator::Agent.providers_schema['providers'][name]
    end

    # schemas returns the json schemais defining the providers configuration schema and the
    # cluster schema for tha cloud provider
    def self.schema(name)
      provider = {}
      # load and parse the providers configuration
      x = HubClustersCreator::Agent.providers_schema
      raise ArgumentError, 'provider is not supported' unless x['providers'].key?(name)

      # retrieve the defaults for this provider
      overrides = x['defaults'][name]['defaults']
      provider = x['schema']
      provider['required'] = x['defaults'][name]['required']
      # filter the properties and retrieve this providers configuration,
      # filling in any defaults
      properties = {}
      provider['properties'].each_pair do |k, v|
        next if v.key?('provider') && !v['provider'].include?(name)
        # fill in any defaults
        v.delete('provider')
        if overrides.key?(k)
          v['examples'] = overrides[k]['examples']
          v['default'] = overrides[k]['default']
        end
        properties[k] = v
      end
      provider['properties'] = properties

      provider
    end

    def self.providers_schema
      YAML.safe_load(File.read("#{__dir__}/providers/schema.yaml"))
    end

    # destroy is responsible is tearing down the cluster
    def destroy(name, options)
      @provider.destroy(name, options)
    end

    # provision is responsible for provisioning the cluster
    # rubocop:disable Lint/RescueException, Metrics/AbcSize
    def provision(options)
      # step: merge in the defaults
      config = HubClustersCreator.defaults(@provider_name).merge(options).transform_keys!(&:to_sym)

      # @step: provision the cluster if not already there
      begin
        schema = HubClustersCreator::Agent.schema(@provider_name)
        # verify the options
        JsonSchema.parse!(schema).validate(config)
        # provision the cluster
        @provider.create(config[:name], config)
      rescue InfrastructureError => e
        error "failed to provision the infrastructure, error: #{e}"
        raise e
      rescue ConfigurationError => e
        error "invalid configuration for cluster, error: #{e}"
        raise e
      rescue InitializerError => e
        error "failed to initialize cluster, error: #{e}"
        raise e
      rescue Exception => e
        error "failed to provision the cluster, error: #{e}"
        raise e
      end
    end
    # rubocop:enable Lint/RescueException, Metrics/AbcSize
  end
end
# rubocop:enable Metrics/MethodLength,Metrics/LineLength
