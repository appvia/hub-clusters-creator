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
        @account_id = optons[:account_id]
        @access_id = options[:access_id]
        @access_key = options[:access_key]
        @region = options[:region]
        @templates_bucket = options[:bucket] || 'hub-clusters-creator-eu-west-2.s3.eu-west-2.amazonaws.com'
        @templates_version = options[:version] || 'v0.0.1'
      end

      # provision is the entrypoint for creating a cluster
      # rubocop:disable Metrics/AbcSize
      def provision(name, config)
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
          { parameter_key: 'NodeVolumeSize', parameter_value: config[:disk_size_gb] },
          { parameter_key: 'NumberOfNodes', parameter_value: config[:size] },
          { parameter_key: 'PrivateSubnet1CIDR', parameter_value: config[:private_subnet1_cidr] },
          { parameter_key: 'PrivateSubnet2CIDR', parameter_value: config[:private_subnet2_cidr] },
          { parameter_key: 'PrivateSubnet3CIDR', parameter_value: config[:private_subnet3_cidr] },
          { parameter_key: 'PublicSubnet1CIDR', parameter_value: config[:public_subnet1_cidr] },
          { parameter_key: 'PublicSubnet2CIDR', parameter_value: config[:public_subnet2_cidr] },
          { parameter_key: 'PublicSubnet3CIDR', parameter_value: config[:public_subnet3_cidr] },
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
        unless client.exists?('aws-auth', 'Kube-system', 'configmaps')
          info 'provition the aws-auth configureation configmap'
          client.kubectl(default_aws_auth(name))

          # @step: ensure we have some nodes
          info 'waiting for some nodes to become available'
          client.wait('aws-node', 'kube-system', 'extensions/v1beta1') do |x|
            x.status.numberReady.positive?
          end
        end

        # @step: provision the cluster
        info 'bootstraping the eks cluster'
        result = HubClustersCreator::Providers::Bootstrap.new(name, 'eks', client, config).bootstrap

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
        next unless stack?(name)

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
        "https://#{@templates_bucket}/eks/#{@templates_version}/#{name}.yaml"
      end

      # cloudformation is responsible for applying the cloudformation template
      # rubocop:disable Metrics/AbcSize
      def cloudformation(name, template_body: nil, template_url: nil, parameters: nil, blocking: true)
        # check the cloudformation template already exists and either
        # update or create it
        stack = {
          stack_name: name,
          capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM],
          on_failure: 'DO_NOTHING',
          parameters: parameters,
          template_body: template_body,
          template_url: template_url
        }
        case stack?(name)
        when true
          info "updating the cloudformation stack: #{name}"
          client.update_stack(stack)
        else
          info "creating the cloudformation stack: #{name}"
          client.create_stack(stack)
        end

        outputs = {}

        # wait for the cloudformation operation to complete
        if blocking
          client.wait_until :stack_create_complete, stack_name: name

          # @step: describe the stacks and get the outputs
          output = client.describe_stacks stack_name: name
          raise StandardError, "failed to find stack: #{name}" if output.stacks.empty?

          output.stacks.first.outputs.each do |x|
            outputs[x.output_key] = x.output_value
          end
        end

        outputs
      end
      # rubocop:enable Metrics/AbcSize

      # build_token is used to construct a token for the eks cluster
      def build_token(name)
        signer = Aws::Sigv4::Signer.new(
          service: 'sts',
          region: @region,
          credentials: @credentials
        )
        # https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/Sigv4/Signer.html#presign_url-instance_method
        presigned_url_string = signer.presign_url(
          http_method: 'GET',
          url: 'https://sts.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15',
          body: '',
          credentials: @credentials,
          expires_in: 60,
          headers: {
            'X-K8s-Aws-Id': name
          }
        )
        kube_token = 'k8s-aws-v1.' + Base64.urlsafe_encode64(presigned_url_string.to_s).chomp('==')

        kube_token
      end

      # stack? checks if the cloudformation stack exists
      def stack?(name)
        list_stacks.map(&:stack_name).include?(name)
      end

      # list_stacks returns a list of cloudformation stacks
      def list_stacks
        client.describe_stacks
      end

      # client returns the cloudformation client
      def client
        @credentials ||= Aws::Credentials.new(@access_id, @access_key)
        @client ||= Aws::CloudFormation::Client.new(
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
