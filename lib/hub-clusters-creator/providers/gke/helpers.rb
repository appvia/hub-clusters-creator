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

# rubocop:disable Metrics/LineLength,Metrics/MethodLength,Metrics/ModuleLength
module HubClustersCreator
  module Providers
    # GCP is the namespace
    module GCP
      # Containers is a GKE container methods
      module Containers
        private

        # gke_locations returns a list of compute locations
        def gke_locations
          @gke.list_project_locations("projects/#{@project}").locations.select do |x|
            x.name.start_with?("#{@region}-")
          end.map(&:name)
        end

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

        # cluster returns a specific cluster
        def cluster(name)
          return nil unless cluster?(name)

          clusters.select { |x| x.name == name }.first
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

        # cluster_spec is responsible for generating a cluster specification from options
        # rubocop:disable Metrics/AbcSize
        def cluster_spec(options)
          locations = gke_locations

          request = Google::Apis::ContainerV1beta1::CreateClusterRequest.new(
            parent: "projects/#{@project}/locations/#{@region}",
            project_id: @project
          )
          request.cluster = Google::Apis::ContainerV1beta1::Cluster.new(
            name: options[:name],
            description: options[:description],
            initial_cluster_version: options[:version],

            #
            ## Addons
            #
            addons_config: Google::Apis::ContainerV1beta1::AddonsConfig.new(
              cloud_run_config: Google::Apis::ContainerV1beta1::CloudRunConfig.new(
                disabled: !options[:enable_cloud_run]
              ),
              horizontal_pod_autoscaling: Google::Apis::ContainerV1beta1::HorizontalPodAutoscaling.new(
                disabled: !options[:enable_horizontal_pod_autoscaler]
              ),
              http_load_balancing: Google::Apis::ContainerV1beta1::HttpLoadBalancing.new(
                disabled: !options[:enable_http_loadbalancer]
              ),
              istio_config: Google::Apis::ContainerV1beta1::IstioConfig.new(
                auth: 'AUTH_MUTUAL_TLS',
                disabled: !options[:enable_istio]
              ),
              kubernetes_dashboard: Google::Apis::ContainerV1beta1::KubernetesDashboard.new(
                disabled: true
              ),
              network_policy_config: Google::Apis::ContainerV1beta1::NetworkPolicyConfig.new(
                disabled: false
              )
            ),

            maintenance_policy: Google::Apis::ContainerV1beta1::MaintenancePolicy.new(
              window: Google::Apis::ContainerV1beta1::MaintenanceWindow.new(
                daily_maintenance_window: Google::Apis::ContainerV1beta1::DailyMaintenanceWindow.new(
                  start_time: options[:maintenance_window]
                )
              )
            ),

            #
            ## Authentication
            #
            master_auth: Google::Apis::ContainerV1beta1::MasterAuth.new(
              client_certificate_config: Google::Apis::ContainerV1beta1::ClientCertificateConfig.new(
                issue_client_certificate: false
              )
            ),

            #
            ## Network
            #
            ip_allocation_policy: Google::Apis::ContainerV1beta1::IpAllocationPolicy.new(
              cluster_ipv4_cidr_block: options[:cluster_ipv4_cidr],
              create_subnetwork: options[:create_subnetwork],
              services_ipv4_cidr_block: options[:services_ipv4_cidr],
              subnetwork_name: options[:subnetwork],
              use_ip_aliases: true
            ),
            locations: locations,

            #
            ## Features
            #
            monitoring_service: ('monitoring.googleapis.com/kubernetes' if options[:enable_monitoring]),
            logging_service: ('logging.googleapis.com/kubernetes' if options[:enable_logging]),

            binary_authorization: Google::Apis::ContainerV1beta1::BinaryAuthorization.new(
              enabled: options[:enable_binary_authorization]
            ),
            legacy_abac: Google::Apis::ContainerV1beta1::LegacyAbac.new(
              enabled: false
            ),
            network_policy: Google::Apis::ContainerV1beta1::NetworkPolicy.new(
              enabled: options[:enable_network_policies]
            ),
            pod_security_policy_config: Google::Apis::ContainerV1beta1::PodSecurityPolicyConfig.new(
              enabled: options[:enable_pod_security_policies]
            ),

            #
            ## Node Pools
            #
            node_pools: [
              Google::Apis::ContainerV1beta1::NodePool.new(
                autoscaling: Google::Apis::ContainerV1beta1::NodePoolAutoscaling.new(
                  autoprovisioned: false,
                  enabled: options[:enable_autoscaler],
                  max_node_count: options[:max_size],
                  min_node_count: options[:size]
                ),
                config: Google::Apis::ContainerV1beta1::NodeConfig.new(
                  disk_size_gb: options[:disk_size_gb],
                  image_type: options[:image_type],
                  machine_type: options[:machine_type],
                  oauth_scopes: [
                    'https://www.googleapis.com/auth/compute',
                    'https://www.googleapis.com/auth/devstorage.read_only',
                    'https://www.googleapis.com/auth/logging.write',
                    'https://www.googleapis.com/auth/monitoring'
                  ],
                  preemptible: options[:preemptible]
                ),
                initial_node_count: options[:size],
                locations: locations,
                management: Google::Apis::ContainerV1beta1::NodeManagement.new(
                  auto_repair: options[:enable_autorepair],
                  auto_upgrade: options[:enable_autoupgrade]
                ),
                max_pods_constraint: Google::Apis::ContainerV1beta1::MaxPodsConstraint.new(
                  max_pods_per_node: 110
                ),
                name: 'compute',
                version: options[:version]
              )
            ]
          )

          if options[:enable_private_network]
            request.cluster.private_cluster = true
            request.cluster.private_cluster_config = Google::Apis::ContainerV1beta1::PrivateClusterConfig.new(
              enable_private_endpoint: options[:enable_private_endpoint],
              enable_private_nodes: true,
              master_ipv4_cidr_block: options[:master_ipv4_cidr_block]
            )

            # @step: do we have any authorized cidr's
            if options[:authorized_master_cidrs].size.positive?
              request.cluster.master_authorized_networks_config = Google::Apis::ContainerV1beta1::MasterAuthorizedNetworksConfig.new(
                cidr_blocks: [],
                enabled: true
              )
              options[:authorized_master_cidrs].each do |x|
                block = Google::Apis::ContainerV1beta1::CidrBlock.new(
                  cidr_block: x[:cidr],
                  display_name: x[:name]
                )

                request.cluster.master_authorized_networks_config.cidr_blocks.push(block)
              end
            end
          end
          request
        end
        # rubocop:enable Metrics/AbcSize
      end
    end
  end
  # rubocop:enable Metrics/LineLength,Metrics/MethodLength
end

# rubocop:disable Metrics/LineLength,Metrics/MethodLength
module HubClustersCreator
  module Providers
    # GCP namespaces the GCP methods
    module GCP
      # Compute provides some helper methods / functions to the GCP agent
      module Compute
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

        def network(name)
          networks.items.select { |x| x.name == name }.first
        end

        # networks returns a list of networks in the region and project
        def networks
          @compute.list_networks(@project)
        end

        # peered_networks returns a list of peered destinations
        def peered_networks(name)
          raise ArgumentError, 'network does not exist' unless network?(name)

          list = []
          (network(name).peerings || []).each do |x|
            options = {
              direction: 'incoming',
              peering_name: x.name,
              region: @region
            }
            @compute.list_network_peering_routes(@project, name, options).items.each do |p|
              list.push(p)
            end
          end
          list
        end

        # subnet? checks if the subnet exists in the project, network and region
        def subnet?(name, network)
          subnets(network).map(&:name).include?(name)
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
          @compute.list_subnetworks(@project, @region).items.select do |x|
            x.network.end_with?(network)
          end
        end
      end
    end
  end
  # rubocop:enable Metrics/LineLength,Metrics/MethodLength,Metrics/ModuleLength
end
