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

module GCP
  # Helper provides some helper methods / functions to the GCP agent
  module Helper
    # router returns a specfic router
    def router(name)
      r = routers.select { |x| x.name == name }.first
      yield r if block_given?
      r
    end

    # router? check if the router exists
    def router?(name)
      routers.map(&:name).include?(name)
    end

    # routers returns the list of routers
    def routers
      list = @compute.list_routers(@project, @region).items
      list.each { |x| yield x } if block_given?
      list
    end

    # network? checks if the network exists in the region and project
    def network?(name)
      networks.items.map(&:name).include?(name)
    end

    # networks returns a list of networks in the region and project
    def networks
      list = @compute.list_networks(@project)
      list.each { |x| yield x } if block_given?
      list
    end

    # subnet? checks if the subnet exists in the project, network and region
    def subnet?(name, network)
      subnets(network).include?(name)
    end

    # dns is responsible for adding / updating a dns record in a zone
    def dns(src, dest, zone, record = 'A')
      raise ArgumentError, "the managed zone: #{zone} does not exist" unless domain?(zone)

      hostname = "#{src}.#{zone}."

      change = Google::Apis::DnsV1::Change.new(
        additions: [
          Google::Apis::DnsV1::ResourceRecordSet.new(
            kind: 'dns#resourceRecordSet',
            name: hostname,
            rrdatas: [dest],
            ttl: 120,
            type: record
          )
        ]
      )

      # @step: check a record already exists and if so add for deletion
      dns_records(zone).rrsets.each do |x|
        next unless x.name == hostname

        change.deletions = [x]
      end

      managed_zone = domain(zone)
      @dns.create_change(@project, managed_zone.name, change)
    end

    # dns_records returns a list of dns recordsets
    def dns_records(zone)
      raise ArgumentError, "the managed zone: #{zone} does not exist" unless domain?(zone)

      managed_zone = domain(zone)
      @dns.list_resource_record_sets(@project, managed_zone.name)
    end

    # domain? checks if the domain exists
    def domain?(name)
      domains.map { |x| x.dns_name.chomp('.') }.include?(name)
    end

    # domain returns a specific domain
    def domain(name)
      domains.select { |x| x.dns_name.chomp('.') == name }.first
    end

    # domains provides a list of domains
    def domains
      @dns.list_managed_zones(@project).managed_zones
    end

    # subnets returns a list of subnets in the network
    def subnets(network)
      list = @compute.list_subnetworks(@project, @region).items.select do |x|
        x.network.end_with?(network)
      end.map(&:name)
      list.each { |x| yield x } if block_given?
      list
    end
  end
  # rubocop:enable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
end
