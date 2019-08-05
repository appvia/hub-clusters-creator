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

require 'aws-sdk-cloudformation'
require 'aws-sdk-route53'
require 'aws-sigv4'
require 'base64'
require 'cgi'

# rubocop:disable Metrics/LineLength,Metrics/MethodLength,Metrics/ClassLength
module HubClustersCreator
  module Providers
    # EKS provides the EKS implementation
    class EKS
      include Errors
      include Logging

      def initialize(options)
        @account_id = options[:account_id]
        @access_id = options[:access_id]
        @access_key = options[:access_key]
        @region = options[:region]
        @templates_bucket = options[:bucket] || 'hub-clusters-creator-eu-west-2'
        @templates_version = options[:version] || 'eks/v0.0.1'
      end

      # create is the entrypoint for creating a cluster
      # rubocop:disable Metrics/AbcSize
      def create(name, config)
        # @step: build the paramaters
        parameters = [
          { parameter_key: 'ClusterName', parameter_value: name },
          { parameter_key: 'AvailabilityZones', parameter_value: config[:availability_zones] },
          { parameter_key: 'BucketName', parameter_value: @templates_bucket },
          { parameter_key: 'BucketVersion', parameter_value: @templates_version },
          { parameter_key: 'ClusterAutoScaler', parameter_value: 'Enabled' },
          { parameter_key: 'KeyPairName', parameter_value: config[:ssh_keypair] },
          { parameter_key: 'KubernetesVersion', parameter_value: config[:version] },
          { parameter_key: 'NodeGroupName', parameter_value: 'compute' },
          { parameter_key: 'NodeInstanceType', parameter_value: config[:machine_type] },
          { parameter_key: 'NodeVolumeSize', parameter_value: config[:disk_size_gb].to_s },
          { parameter_key: 'NumberOfAZs', parameter_value: config[:availability_zones].split(',').size.to_s },
          { parameter_key: 'NumberOfNodes', parameter_value: config[:size].to_s },
          { parameter_key: 'PrivateSubnet1CIDR', parameter_value: config[:private_subnet1_cidr] },
          { parameter_key: 'PrivateSubnet2CIDR', parameter_value: config[:private_subnet2_cidr] },
          { parameter_key: 'PrivateSubnet3CIDR', parameter_value: config[:private_subnet3_cidr] },
          { parameter_key: 'PublicSubnet1CIDR', parameter_value: config[:public_subnet1_cidr] },
          { parameter_key: 'PublicSubnet2CIDR', parameter_value: config[:public_subnet2_cidr] },
          { parameter_key: 'PublicSubnet3CIDR', parameter_value: config[:public_subnet3_cidr] },
          { parameter_key: 'RemoteAccessCIDR', parameter_value: '0.0.0.0/0' },
          { parameter_key: 'VPCCIDR', parameter_value: config[:network] }
        ]

        # @step: provision the cloudformation stacks
        stack_name = 'aws-cluster'
        info "provisioning the cloudFormation: #{stack_name}"
        info "using the template from: #{template_path(stack_name)}"

        outputs = cloudformation(name, template_url: template_path(stack_name), parameters: parameters)

        info 'waiting for the kube apiserver to become available'
        client = HubClustersCreator::Kube.new(outputs['EKSEndpoint'], token: build_token(name))
        client.wait_for_kubeapi

        # @step: check if the awa-auth configmap exists already, we never overwrite
        unless client.exists?('aws-auth', 'kube-system', 'configmaps')
          info 'provition the aws-auth configureation configmap'
          client.kubectl(default_aws_auth(name))

          # @step: ensure we have some nodes
          info 'waiting for some nodes to become available'
          client.wait('aws-node', 'kube-system', 'daemonsets', version: 'extensions/v1beta1') do |x|
            puts x.status.numberReady.positive?
            x.status.numberReady.positive?
          end
        end

        # @step: provision the cluster
        info 'bootstraping the eks cluster'
        result = HubClustersCreator::Providers::Bootstrap.new(name, 'eks', client, config).bootstrap
        address = result[:grafana][:hostname]

        info 'adding the dns entry for the grafana dashboard'
        dns(config[:grafana_hostname], address, config[:domain])

        {
          cluster: {
            ca: outputs['EKSCA'],
            endpoint: 'https://' + outputs['EKSEndpoint'],
            global_service_account_name: 'default',
            global_service_account_token: Base64.decode64(client.account('robot', 'default')),
            service_account_name: 'sysadmin',
            service_account_namespace: 'sysadmin',
            service_account_token: Base64.decode64(client.account('sysadmin'))
          },
          config: config,
          services: {
            grafana: {
              api_key: result[:grafana][:key],
              url: "http://#{config[:grafana_hostname]}.#{config[:domain]}"
            }
          }
        }
      end
      # rubocop:enable Metrics/AbcSize

      # destroy is responsible for deleting the cluster
      def destroy(stack)
        return unless stack?(name)

        # delete the cloudformation stack
        info "deleting the cloudformation stack: #{stack}"
        client.delete_stack stack_name: stack
        # wait for the deletion to finish
        cloudformation.wait_until :stack_delete_complete, stack_name: stack
        # check the status of the result
      end

      private

      # template_path returns the template url
      def template_path(name)
        "https://#{@templates_bucket}.s3.amazonaws.com/#{@templates_version}/#{name}.yaml"
      end

      # cloudformation is responsible for applying the cloudformation template
      def cloudformation(name, template_url: nil, parameters: nil, blocking: true)
        # check the cloudformation template already exists and either
        # update or create it
        wait_name = :stack_create_complete
        case stack?(name)
        when true
          info "updating the cloudformation stack: '#{name}'"
          client.update_stack(
            stack_name: name,
            capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM],
            parameters: parameters,
            template_url: template_url
          )
          wait_name = :stack_update_complete
        else
          info "creating the cloudformation stack: '#{name}'"
          client.create_stack(
            stack_name: name,
            capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM],
            on_failure: 'DO_NOTHING',
            parameters: parameters,
            template_url: template_url,
            timeout_in_minutes: 20
          )
        end

        # wait for the cloudformation operation to complete
        if blocking
          begin
            info "waiting for the stack: '#{name}' to reach state: '#{wait_name}'"
            client.wait_until wait_name, stack_name: name
          rescue Aws::Waiters::Errors::FailureStateError => e
            error "failed to create or update stack: '#{name}', error: #{e}"
            raise InfrastructureError, e
          end
        end
        # @step: return the outputs from the stack
        get_stack_outputs(name)
      end

      # build_token is used to construct a token for the eks cluster
      def build_token(name)
        # Note - sts only has ONE endpoint (not regional) so 'us-east-1'
        # hardcoding should be OK
        signer = Aws::Sigv4::Signer.new(
          service: 'sts',
          region: 'us-east-1',
          credentials_provider: @credentials
        )
        presigned_url_string = signer.presign_url(
          url: 'https://sts.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15',
          body: '',
          expires_in: 60,
          headers: { 'X-K8s-Aws-Id' => name },
          http_method: 'GET'
        )

        'k8s-aws-v1.' + Base64.urlsafe_encode64(presigned_url_string.to_s).chomp('==')
      end

      # stack? checks if the cloudformation stack exists
      def stack?(name)
        list_stacks.map(&:stack_name).include?(name)
      end

      # list_stacks returns a list of cloudformation stacks
      def list_stacks
        client.describe_stacks.stacks
      end

      # get_stack_outputs retrieves the stack and extracts the output
      def get_stack_outputs(name)
        list = client.describe_stacks stack_name: name
        raise StandardError, "stack: '#{name}' does not exist" if list.stacks.empty?

        outputs = {}
        list.stacks.first.outputs.each do |x|
          outputs[x.output_key] = x.output_value
        end

        outputs
      end

      # client returns the cloudformation client
      def client
        @credentials ||= Aws::Credentials.new(@access_id, @access_key)
        @client ||= Aws::CloudFormation::Client.new(
          credentials: @credentials,
          region: @region
        )
      end

      # dns is responsible for adding a dns record
      def dns(source, dest, zone, record: 'CNAME', ttl: 60)
        hosting_zone = get_hosting_zone(zone)
        if hosting_zone.nil?
          raise ArgumentError, "no hosting domain found for: '#{zone}'"
        end

        fqdn = "#{source}.#{zone}"

        route53.change_resource_record_sets(
          change_batch: {
            changes: [
              {
                action: 'UPSERT',
                resource_record_set: {
                  name: fqdn,
                  resource_records: [{ value: dest }],
                  ttl: ttl,
                  type: record
                }
              }
            ]
          },
          hosted_zone_id: hosting_zone.id
        )
      end

      # get_hosting_zone is responsible for getting the hosting zone
      def get_hosting_zone(domain)
        route53.list_hosted_zones.hosted_zones.select do |x|
          x.name == "#{domain}."
        end.first
      end

      # route53 returns a route53 client
      def route53
        @route53 ||= Aws::Route53::Client.new(
          credentials: @credentials,
          region: @region
        )
      end

      def default_aws_auth(name)
        <<~YAML
          ---
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: aws-auth
            namespace: kube-system
          data:
            mapRoles: |
              - rolearn: arn:aws:iam::#{@account_id}:role/#{name}-instance-role
                username: system:node:{{EC2PrivateDNSName}}
                groups:
                  - system:bootstrappers
                  - system:nodes
        YAML
      end
    end
  end
end
# rubocop:enable Metrics/MethodLength,Metrics/LineLength,Metrics/ClassLength
