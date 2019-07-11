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
require 'google/apis/dns_v1'
require 'googleauth'

class GKE
  # Compute are a collection of methods used to interact with GCP
  # rubocop:disable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
  include GCP::Helper
  include GCP::Auth

  Container = Google::Apis::ContainerV1beta1
  Compute = Google::Apis::ComputeV1
  Dns = Google::Apis::DnsV1

  attr_accessor :project, :region, :authorizer

  def initialize(account, project, region)
    @account = account
    @project = project
    @region = region
    @compute = Compute::ComputeService.new
    @gke = Container::ContainerService.new
    @dns = Dns::DnsService.new

    @compute.authorization = authorize
    @gke.authorization = authorize
    @dns.authorization = authorize
  end

  # locations returns a list of compute locations
  def locations
    @gke.list_project_locations("projects/#{@project}").locations.select do |x|
      x.name.start_with?("#{@region}-")
    end.map(&:name)
  end

  # create is used to create a gke cluster
  def create(resource)
    path = "projects/#{@project}/locations/#{@region}"
    c = @gke.create_project_location_cluster(path, resource)
    yield c if block_given?
    c
  end

  # destroy is used to kill off a cluster
  def destroy(name)
    @gke.delete_project_location_cluster("projects/#{@project}/locations/#{@region}/clusters/#{name}")
  end

  # patch_router is a wrapper for the patch router
  def patch_router(name, router)
    @compute.patch_router(@project, @region, name, router)
  end

  # default_cloud_nat returns a default cloud nat configuration
  def default_cloud_nat(name = 'cloud-nat')
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
  # rubocop:disable Lint/RescueException
  def hold_for_operation(id, interval = 10, timeout = 900)
    max_attempts = timeout / interval
    retries = attempts = 0

    while attempts < max_attempts
      begin
        resp = operation(id)
        return resp if !resp.nil? && resp.status == 'DONE'
      rescue Exception => e
        raise Exception, "failed waiting on operation: #{id}, error: #{e}" if retries > 10

        retries += 1
      end
      sleep(interval)
      attempts += 1
    end

    raise Exception, "operation: #{id} has timed out waiting to finish"
  end
  # rubocop:enable Lint/RescueException

  # operation returns the current status of an operation
  def operation(id)
    @gke.get_project_location_operation("projects/#{@project}/locations/#{@region}/operations/*", operation_id: id)
  end

  # operations returns a list of all operations
  def operations
    list = @gke.list_project_location_operations("projects/#{@project}/locations/#{@region}").operations
    list.each { |x| yield x } if block_given?
    list
  end

  # operations_by_resource returns any operations filtered by the resource
  def operations_by_resource(name, resource, operation_type = '')
    operations.select do |x|
      next unless x.target_link.end_with?("#{resource}/#{name}")
      next if !operation_type.empty? && (!x.operation_type == operation_type)

      true
    end
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
    path = "projects/#{@project}/locations/#{@region}"
    list = @gke.list_zone_clusters(nil, nil, parent: path).clusters || []
    list.each { |x| yield x } if block_given?
    list
  end
end
