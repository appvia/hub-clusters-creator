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
require 'hub-clusters-creator/providers/eks/eks.rb'
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
      when 'aks'
        @provider = HubClustersCreator::Providers::AKS.new(
          client_id: provider[:client_id],
          client_secret: provider[:client_secret],
          region: provider[:region],
          subscription: provider[:subscription],
          tenant: provider[:tenant]
        )
      when 'eks'
        @provider = HubClustersCreator::Providers::EKS.new(
          account_id: provider[:account_id],
          access_id: provider[:access_id],
          access_key: provider[:access_key],
          region: provider[:region]
        )
      when 'gke'
        @provider = HubClustersCreator::Providers::GKE.new(
          account: provider[:account],
          project: provider[:project],
          region: provider[:region]
        )
      else
        raise ArgumentError, "cloud provider: #{@provider_name} not supported"
      end
    end
    # rubocop:enable Metrics/AbcSize

    # providers provides a list of providers
    def self.providers
      %w[aks eks gke]
    end

    # defaults builds the default from the schema
    def self.defaults(name)
      values = {}
      cluster_schema(name)['properties'].reject { |x, _v| x == 'authorized_master_cidrs' }.each do |k, v|
        values[k.to_sym] = v['default']
      end
      # @TODO find a better way of doing this
      unless values[:authorized_master_cidrs]
        values[:authorized_master_cidrs] = [{ name: 'any', cidr: '0.0.0.0/0' }]
      end
      values
    end

    # provider_schema returns the provider schema
    def self.provider_schema(name)
      schemas(name).first
    end

    # cluster_schema returns a cluster schema for a specific provider
    def self.cluster_schema(name)
      schemas(name).last
    end

    # schemas returns the json schemais defining the providers configuration schema and the
    # cluster schema for tha cloud provider
    def self.schemas(name)
      file = "#{__dir__}/providers/#{name}/schema.yaml"
      raise ArgumentError, "provider: '#{name}' is not supported" unless File.exist?(file)

      # loads and parses both the provider and cluster schema
      YAML.load_stream(File.read(file))
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
        schema = HubClustersCreator::Agent.cluster_schema(@provider_name)
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
