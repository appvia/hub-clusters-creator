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
require 'google/apis/compute_beta'
require 'google/apis/container_v1beta1'
require 'google/apis/dns_v1'
require 'googleauth'

require 'hub-clusters-creator/errors'
require 'hub-clusters-creator/kube/kube'
require 'hub-clusters-creator/logging'
require 'hub-clusters-creator/providers/bootstrap'
require 'hub-clusters-creator/providers/gke/helpers'

require 'base64'

# rubocop:disable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
module HubClustersCreator
  module Providers
    # GKE provides the GKE implmentation
    class GKE
      DEFAULT_PSP_CLUSTER_ROLE = <<~YAML
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRole
        metadata:
          name: default:psp
        rules:
        - apiGroups:
          - policy
          resourceNames:
          - gce.unprivileged-addon
          resources:
          - podsecuritypolicies
          verbs:
          - use
      YAML

      DEFAULT_PSP_CLUSTERROLE_BINDING = <<~YAML
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: default:psp
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: default:psp
        subjects:
        - apiGroup: rbac.authorization.k8s.io
          kind: Group
          name: system:authenticated
        - apiGroup: rbac.authorization.k8s.io
          kind: Group
          name: system:serviceaccounts
      YAML

      # Compute are a collection of methods used to interact with GCP
      include Errors
      include GCP::Compute
      include GCP::Containers
      include Logging

      Container = Google::Apis::ContainerV1beta1
      Compute = Google::Apis::ComputeBeta
      Dns = Google::Apis::DnsV1

      def initialize(provider)
        @account = provider[:account]
        @project = provider[:project]
        @region = provider[:region]
        @compute = Compute::ComputeService.new
        @gke = Container::ContainerService.new
        @dns = Dns::DnsService.new
        @client = nil

        @compute.authorization = authorize
        @gke.authorization = authorize
        @dns.authorization = authorize
      end

      # create is responsible for building the infrastructure
      # rubocop:disable Metrics/AbcSize
      def create(name, config)
        # @step: validate the configuration
        begin
          validate(config)
        rescue StandardError => e
          raise ConfigurationError, "invalid configuration, error: #{e}"
        end

        # @step: provision the infrastructure
        begin
          provision_gke(name, config)
        rescue StandardError => e
          raise InfrastructureError, "failed to provision cluster: '#{name}', error: #{e}"
        end

        # @step: initialize the cluster
        begin
          config[:credentials] = @account
          result = provision_cluster(name, config)
          c = cluster(name)
          config.delete(:credentials)
        rescue StandardError => e
          raise InitializerError, "failed to initialize the cluster: '#{name}', error: #{e}"
        end

        {
          cluster: {
            ca: c.master_auth.cluster_ca_certificate,
            endpoint: "https://#{c.endpoint}",
            service_account_name: 'sysadmin',
            service_account_namespace: 'kube-system',
            service_account_token: Base64.decode64(@client.account('sysadmin'))
          },
          config: config,
          services: result
        }
      end
      # rubocop:enable Metrics/AbcSize

      # destroy is used to kill off a cluster
      def destroy(name)
        @gke.delete_project_location_cluster("projects/#{@project}/locations/#{@region}/clusters/#{name}")
      end

      private

      # provision_gke is responsible for provisioning the infrastucture
      # rubocop:disable Metrics/AbcSize
      def provision_gke(name, config)
        info "checking if the gke cluster: '#{name}' exists"
        if cluster?(name)
          info "skipping the creation of cluster: '#{name}' as it already exists"
        else
          info "cluster: '#{name}' does not exist, creating now"
          path = "projects/#{@project}/locations/#{@region}"
          operation = @gke.create_project_location_cluster(path, cluster_spec(config))

          info "waiting for the cluster: '#{name}' to be created, operation: '#{operation.name}'"
          status = hold_for_operation(operation.name)
          unless status.status_message.nil?
            raise InfrastructureError, "operation: '#{operation.operation_type}' failed, error: #{operation.status_message}"
          end
        end
        gke = cluster(name)

        # @step: create a cloud-nat device if private networking enabled
        # and nothing exists already
        if config[:enable_private_network]
          info 'checking if cloud-nat device has been created'
          router('router') do |x|
            unless x.nats
              x.nats = default_cloud_nat('cloud-nat')
              patch_router('router', x)
            end
          end

          info 'creating a firewall rule to permit master access (apiservices)'
          add_firewall_rule("allow-#{config[:name]}-masters",
                            config[:network],
                            config[:master_ipv4_cidr_block],
                            config[:name],
                            ['tcp:443,5443,8443'])
        end
      end
      # rubocop:enable Metrics/AbcSize

      # provision_cluster is responsible for kickstarting the cluster
      # rubocop:disable Metrics/AbcSize
      def provision_cluster(name, config)
        info "waiting for the master api endpoint to be available on cluster: #{name}"
        thing = cluster(name)
        @client = HubClustersCreator::Kube.new(thing.endpoint, token: authorize.access_token)
        @client.wait_for_kubeapi

        # @step: if psp is enabled we need to add the roles and bindings
        info 'creating the default psp binding to unpriviledged policy'
        @client.kubectl(DEFAULT_PSP_CLUSTER_ROLE)
        @client.kubectl(DEFAULT_PSP_CLUSTERROLE_BINDING)

        # @step: bootstrap the cluster and wait
        HubClustersCreator::Providers::Bootstrap.new(name, 'gke', @client, config).bootstrap
      end
      # rubocop:enable Metrics/AbcSize

      # validate is responsible for validating the options for cluster creation
      # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      def validate(config)
        raise ConfigurationError, "domain: #{config[:domain]} does not exist within project" unless domain?(config[:domain])
        raise ConfigurationError, 'disk size must be positive' unless config[:disk_size_gb].positive?
        raise ConfigurationError, 'size must be positive' unless config[:size].positive?

        # @check the networking options
        raise ConfigurationError, 'the network does not exist' unless network?(config[:network])
        raise ConfigurationError, 'the subnetwork does not exist' unless subnet?(config[:subnetwork], config[:network]) && !config[:create_subnetwork]
        if config[:enable_private_network] && !config[:master_ipv4_cidr_block]
          raise ConfigurationError, 'you must specify a master_ipv4_cidr_block'
        end

        # These checks only need to be run if the cluster doesn't exists already
        unless cluster?(config[:name])
          # @check if subnets exist - need to do something more clever
          # and check for overlapping subnety really but i can't find a gem
          network_checks = []
          network_checks.push(config[:cluster_ipv4_cidr]) unless config[:cluster_ipv4_cidr].empty?
          network_checks.push(config[:services_ipv4_cidr]) unless config[:services_ipv4_cidr].empty?

          if config[:enable_private_network]
            network_checks.push(config[:master_ipv4_cidr_block]) unless config[:master_ipv4_cidr_block].empty?
          end

          network_checks.each do |n|
            list = subnets(config[:network]) || []
            list.each do |x|
              raise ConfigurationError, "subnetwork: #{n} already exists" if x.ip_cidr_range.equal?(n)

              (x.secondary_ip_ranges || []).each do |j|
                raise ConfigurationError, "subnetwork: #{n} already exists" if j.ip_cidr_range.equal?(n)
              end
            end
          end

          if config[:enable_private_network]
            # @check for any conflicts in peering
            (peered_networks(config[:network]) || []).each do |n|
              network_checks.each do |x|
                raise ConfigurationError, "conflicting peered network: #{n.dest_range}" if n.dest_range == x
              end
            end
          end
        end

        config
      end
      # rubocop:enable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity

      # patch_router is a wrapper for the patch router
      def patch_router(name, router)
        @compute.patch_router(@project, @region, name, router)
      end

      # default_cloud_nat returns a default cloud nat configuration
      def default_cloud_nat(name = 'cloud-nat')
        [
          Google::Apis::ComputeBeta::RouterNat.new(
            log_config: Google::Apis::ComputeBeta::RouterNatLogConfig.new(enable: false, filter: 'ALL'),
            name: name,
            nat_ip_allocate_option: 'AUTO_ONLY',
            source_subnetwork_ip_ranges_to_nat: 'ALL_SUBNETWORKS_ALL_IP_RANGES'
          )
        ]
      end

      # authorize is responsible for providing an access token to operate
      def authorize(scopes = ['https://www.googleapis.com/auth/cloud-platform'])
        if @authorizer.nil?
          @authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(@account),
            scope: scopes
          )
          @authorizer.fetch_access_token!
        end
        @authorizer
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength,Metrics/LineLength,Metrics/MethodLength
