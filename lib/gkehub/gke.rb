# frozen_string_literal: true

require 'google/apis/compute_v1'
require 'google/apis/container_v1beta1'
require 'googleauth'

# rubocop:disable Metrics/LineLength
module GKE
  # Compute are a collection of methods used to interact with GCP
  module Compute
    Container = Google::Apis::ContainerV1beta1
    Compute = Google::Apis::ComputeV1

    # service_account_credentials returns the credentials for a service account
    def service_account_credentials(endpoint, name)
      client = kube_client(endpoint)
      sa = client.api('v1').resource('serviceaccounts', namespace: 'kube-system').get(name)
      secret = client.api('v1').resource('secrets', namespace: 'kube-system').get(sa.secrets.first.name)
      secret.data.token
    end

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
    # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize,Metrics/MethodLength
    def hold_for_operation(id, interval = 10, max_retries = 3, max_timeout = 15 * 60)
      max_attempts = max_timeout / interval
      retries = attempts = 0

      # @TODO this feels like a very naive timeout, but i don't know ruby too well so :-)
      while retries < max_retries
        begin
          resp = get_operation_status(id)
          if !resp.nil? && (resp.status == 'DONE')
            if !resp.status_message.nil? && !resp.status_message.empty?
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
    # rubocop:enable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize,Metrics/MethodLength

    # get_operation_status returns the current status of an operation
    def get_operation_status(id, project = @project, region = @region)
      gke.get_project_location_operation("projects/#{project}/locations/#{region}/operations/*", operation_id: id)
    end

    # list_clusters returns a list of clusters
    def list_clusters(project = @project, region = @region)
      gke.list_zone_clusters(nil, nil, parent: "projects/#{project}/locations/#{region}").clusters || []
    end

    # list_locations returns a list of compute locations
    def list_locations(region = @region, project = @project)
      gke.list_project_locations("projects/#{project}").locations.select do |x|
        x.name.start_with?("#{region}-")
      end.map(&:name)
    end

    # authorize is responsible for providing an access token to operate
    def authorize
      unless defined?(@credentials)
        @authorizer ||= Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(@account),
          scope: 'https://www.googleapis.com/auth/cloud-platform'
        )
        @credentials = @authorizer.fetch_access_token!
      end
      @authorizer
    end

    # router returns a specfic router
    def router(name, project = @project, region = @region)
      routers(project, region).select { |x| x.name == name }.first
    end

    # router? check if the router exists
    def router?(name, project = @project, region = @region)
      routers(project, region).map(&:name).include?(name)
    end

    # routers returns the list of routers
    def routers(project = @project, region = @region)
      compute.list_routers(project, region).items
    end

    # network? checks if the network exists in the region and project
    def network?(name, project = @project, region = @region)
      networks(project, region).items.map(&:name).include?(name)
    end

    # networks returns a list of networks in the region and project
    def networks(project = @project, _region = @region)
      compute.list_networks(project)
    end

    # subnet? checks if the subnet exists in the project, network and region
    def subnet?(name, network, _project = @project, _region = @region)
      subnets(network).include?(name)
    end

    # subnets returns a list of subnets in the network
    def subnets(network, region = @region, project = @project)
      compute.list_subnetworks(project, region).items.select do |x|
        x.network.end_with?(network)
      end.map(&:name)
    end

    # exist? check if a gke cluster exists
    def exist?(name, project = @project, region = @region)
      list_clusters(project, region).map(&:name).include?(name)
    end

    # compute returns a gcp complete client for the region
    def compute
      unless defined?(@compute)
        @compute = Compute::ComputeService.new
        @compute.authorization = authorize
      end
      @compute
    end

    # client returns the container client for us
    def gke
      unless defined?(@gke)
        @gke = Container::ContainerService.new
        @gke.authorization = authorize
      end
      @gke
    end
  end
end
# rubocop:enable Metrics/LineLength
