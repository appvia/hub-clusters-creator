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

# rubocop:disable Metrics/LineLength,Metrics/MethodLength
module Clusters
  module Providers
    # Azure is the AKS namespace
    module Azure
      # Helpers providers a collection of useful methods
      module Helpers
        private

        # wait_on_deployment waits for a deployment to finish - technically the create_or_update
        # is blocking and works, but the internet here is shite and keeps dropping out
        # rubocop:disable Lint/RescueException
        def wait_on_deployment(group, name, interval: 10, timeout: 900)
          max_attempts = timeout / interval
          retries = attempts = 0

          while attempts < max_attempts
            begin
              return if deployment(group, name).properties.provisioning_state == 'Succeeded'
            rescue Exception => e
              raise Exception, "failed waiting on deployment: #{id}, error: #{e}" if retries > 10

              retries += 1
            end
            sleep(interval)
            attempts += 1
          end

          raise Exception, "deployment: '#{name}' in resource group: '#{group}' has timed out"
        end
        # rubocop:enable Lint/RescueException

        def dns(src, dest, zone, ttl: 120)
          raise ArgumentError, "the domain: #{zone} does not exist" unless domain?(zone)

          zone = domain(zone)
          resource_group = zone.id.split('/')[4]
          address = Azure::Dns::Mgmt::V2017_10_01::Models::ARecord.new
          address.ipv4address = dest
          record = Azure::Dns::Mgmt::V2017_10_01::Models::RecordSet.new
          record.name = src
          record.ttl = ttl
          record.arecords = [address]

          @dns.record_sets.create_or_update(resource_group, zone, src, 'A', record)
        end

        def domain?(name)
          domains.map(&:name).include?(name)
        end

        def domains
          @dns.zones.list
        end

        def deployment(group, name)
          deployments(group).select { |x| x.name == name }.first
        end

        def deployment?(name, group)
          deployments(group).map(&:name).include?(name)
        end

        def deployments(group)
          @client.deployments.list_by_resource_group(group)
        end

        def managed_cluster?(name)
          managed_clusters.map(&:name).include?(name)
        end

        def managed_clusters
          @containers.managed_clusters.list
        end

        # resource_group? check is the resource group exists
        def resource_group?(name)
          resource_groups.map(&:name).include?(name)
        end

        # resource_groups returns a list of resource groups
        def resource_groups
          @client.resource_groups.list
        end
      end
    end
  end
end
# rubocop:enable Metrics/LineLength,Metrics/MethodLength
