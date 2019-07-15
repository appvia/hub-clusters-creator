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
require 'hub-clusters-creator/providers/azure/azure.rb'
require 'hub-clusters-creator/providers/gcp/gke.rb'

# rubocop:disable Metrics/MethodLength,Metrics/LineLength
module Clusters
  # Agent is the main agent class
  class Agent
    include Errors
    include Logging

    def initialize(provider)
      case provider[:provider]
      when 'gcp'
        @provider = Clusters::Providers::GKE.new(
          account: provider[:account],
          project: provider[:project],
          region: provider[:region]
        )
      when 'aks'
        @provider = Clusters::Providers::AKS.new(
          client_id: provider[:client_id],
          client_secret: provider[:client_secret],
          region: provider[:region],
          subscription: provider[:subscription],
          tenant: provider[:tenant]
        )
      else
        raise ArgumentError, "cloud provider: #{provider[:provider]} not supported"
      end
    end

    # defaults builds the default from the schema
    def defaults
      values = {}
      schema['properties'].reject { |x, _v| x == 'authorized_master_cidrs' }.each do |k, v|
        values[k.to_sym] = v['default']
      end
      # @TODO find a better way of doing this
      unless values[:authorized_master_cidrs]
        values[:authorized_master_cidrs] = [{ name: 'any', cidr: '0.0.0.0/0' }]
      end
      values
    end

    # schema returns the json schema defining all the options we support
    def schema(provider = 'gcp')
      @schema ||= YAML.safe_load(File.read("#{ROOT}/hub-clusters-creator/schema.yaml"))
      generated = @schema.dup
      generated['properties'] = @schema['properties'].select do |_name, x|
        x['provider'].include?(provider) || x['provider'].include?('*')
      end
      generated
    end

    # destroy is responsible is tearing down the cluster
    def destroy(name, options)
      @provider.destroy(name, options)
    end

    # provision is responsible for provisioning the cluster
    # rubocop:disable Lint/RescueException
    def provision(options)
      name = options[:name]
      config = defaults.merge(options)

      # @step: provision the cluster if not already there
      begin
        @provider.create(config)
      rescue InfrastructureError => e
        error "failed to provision the infrastructure: #{name}, error: #{e}"
        raise e
      rescue ConfigurationError => e
        error "invalid configuration for cluster: #{name}, error: #{e}"
        raise e
      rescue InitializerError => e
        error "failed to initialize cluster: #{name}, error: #{e}"
        raise e
      rescue Exception => e
        error "failed to provision the cluster: #{name}, error: #{e}"
        raise e
      end
    end
    # rubocop:enable Lint/RescueException
  end
end
# rubocop:enable Metrics/MethodLength,Metrics/LineLength
