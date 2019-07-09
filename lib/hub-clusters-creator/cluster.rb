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
# frozen_string_literal: true

# rubocop:disable Metrics/LineLength,Metrics/ModuleLength,Metrics/MethodLength
module GKE
  # Cluster is a collection of methods for interacting with the gke cluster
  module Cluster
    # cluster_spec is responsible for generating a cluster specification from options
    # rubocop:disable Metrics/AbcSize
    def cluster_spec(options)
      locations = compute.locations

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
          enabled: options[:enable_network_polices]
        ),
        pod_security_policy_config: Google::Apis::ContainerV1beta1::PodSecurityPolicyConfig.new(
          enabled: options[:enable_pod_security_polices]
        ),

        #
        ## Node Pools
        #
        node_pools: [
          Google::Apis::ContainerV1beta1::NodePool.new(
            autoscaling: Google::Apis::ContainerV1beta1::NodePoolAutoscaling.new(
              autoprovisioned: false,
              enabled: options[:enable_autoscaler],
              max_node_count: options[:max_nodes],
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
# rubocop:enable Metrics/LineLength,Metrics/ModuleLength,Metrics/MethodLength
