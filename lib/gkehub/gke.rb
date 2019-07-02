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

require 'google/apis/compute_v1'
require 'google/apis/container_v1beta1'
require 'googleauth'

# rubocop:disable Metrics/LineLength,Metrics/ClassLength
module GKE
  # Compute are a collection of methods used to interact with GCP
  class Compute
    Container = Google::Apis::ContainerV1beta1
    Compute = Google::Apis::ComputeV1

    attr_accessor :project, :region, :authorizer

    def initialize(account, project, region)
      @account = account
      @project = project
      @region = region
      @compute = Compute::ComputeService.new
      @gke = Container::ContainerService.new

      @gke.authorization = authorize
      @compute.authorization = authorize
    end

    # create is used to create a gke cluster
    def create(resource)
      path = "projects/#{@project}/locations/#{@region}"
      @gke.create_project_location_cluster(path, resource)
    end

    # destroy is used to kill off a cluster
    def destroy(name)
      @gke.delete_project_location_cluster("projects/#{@project}/locations/#{@region}/clusters/#{name}")
    end

    # patch_router is a wrapper for the patch router
    def patch_router(_name, router)
      @compute.patch_router(@project, @region, 'router', router)
    end

    # default_nat returns a default cloud nat configuration
    def default_nat(name = 'cloud-nat')
      [
        Google::Apis::ComputeV1::RouterNat.new(
          log_config: Google::Apis::ComputeV1::RouterNatLogConfig.new(enable: false, filter: 'ALL'),
          name: name,
          nat_ip_allocate_option: 'AUTO_ONLY',
          source_subnetwork_ip_ranges_to_nat: 'ALL_SUBNETWORKS_ALL_IP_RANGES'
        )
      ]
    end

    # hold_for_operation is responisble for waiting for an operation to complete or error
    # rubocop:disable Metrics/CyclomaticComplexity,Metrics/AbcSize,Metrics/MethodLength
    def hold_for_operation(id, interval = 10, max_retries = 3, max_timeout = 15 * 60)
      max_attempts = max_timeout / interval
      retries = attempts = 0

      # @TODO this feels like a very naive timeout, but i don't know ruby too well so :-)
      while retries < max_retries
        begin
          resp = operation(id)
          if !resp.nil? && (resp.status == 'DONE')
            if resp.status_message.present?
              raise Exception, "operation: #{x.operation_type} has failed with error message: #{resp.status_message}"
            end

            break
          end
          # @step: throw an exception if we've overrun the max attempts
          raise Exception, "operation: #{x.operation_type}, target: #{x.target_link} has timed out" if attempts > max_attempts

          sleep(interval)
          attempts += 1
        rescue StandardError
          retries += 1
          sleep(5)
        end
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity,Metrics/AbcSize,Metrics/MethodLength

    # operation returns the current status of an operation
    def operation(id)
      @gke.get_project_location_operation("projects/#{@project}/locations/#{@region}/operations/*", operation_id: id)
    end

    # locations returns a list of compute locations
    def locations
      @gke.list_project_locations("projects/#{@project}").locations.select do |x|
        x.name.start_with?("#{@region}-")
      end.map(&:name)
    end

    # router returns a specfic router
    def router(name)
      routers.select { |x| x.name == name }.first
    end

    # router? check if the router exists
    def router?(name)
      routers.map(&:name).include?(name)
    end

    # routers returns the list of routers
    def routers
      @compute.list_routers(@project, @region).items
    end

    # network? checks if the network exists in the region and project
    def network?(name)
      networks.items.map(&:name).include?(name)
    end

    # networks returns a list of networks in the region and project
    def networks
      @compute.list_networks(@project)
    end

    # subnet? checks if the subnet exists in the project, network and region
    def subnet?(name, network)
      subnets(network).include?(name)
    end

    # subnets returns a list of subnets in the network
    def subnets(network)
      @compute.list_subnetworks(@project, @region).items.select do |x|
        x.network.end_with?(network)
      end.map(&:name)
    end

    # cluster returns a specific cluster
    def cluster(name)
      return nil unless cluster?(name)

      clusters.select { |x| x.name = name }.first
    end

    # cluster? check if a gke cluster exists
    def cluster?(name)
      clusters.map(&:name).include?(name)
    end

    # clusters returns a list of clusters
    def clusters
      @gke.list_zone_clusters(nil, nil, parent: "projects/#{@project}/locations/#{@region}").clusters || []
    end

    private

    # authorize is responsible for providing an access token to operate
    def authorize
      if @authorizer.nil?
        @authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(@account),
          scope: 'https://www.googleapis.com/auth/cloud-platform'
        )
        @authorizer.fetch_access_token!
      end
      @authorizer
    end
  end
end
# rubocop:enable Metrics/LineLength,Metrics/ClassLength
