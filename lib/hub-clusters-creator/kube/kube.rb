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

require 'k8s-client'

module HubClustersCreator
  # Kube is a collection of methods for interacting with the kubernetes api
  # rubocop:disable Metrics/LineLength,Metrics/MethodLength,Metrics/ParameterLists
  class Kube
    attr_accessor :endpoint

    def initialize(endpoint, token: nil, client_certificate: nil, client_key: nil, certificate_authority: nil)
      options = {
        ssl_verify_peer: false
      }
      @endpoint = endpoint
      @endpoint = "https://#{endpoint}" unless endpoint.start_with?('https')

      config = K8s::Config.new(
        clusters: [{
          name: 'default',
          cluster: { server: @endpoint, certificate_authority_data: certificate_authority }
        }],
        users: [{
          name: 'default',
          user: {
            token: token,
            client_certificate_data: client_certificate,
            client_key_data: client_key
          }
        }],
        contexts: [{
          name: 'default',
          context: { cluster: 'default', user: 'default' }
        }],
        current_context: 'default'
      )
      @client = K8s::Client.config(config, options)
    end

    # exists? checks if the resource exists
    def exists?(name, namespace, kind, version = 'v1')
      begin
        kind = "#{kind}s" unless kind.end_with?('s')
        @client.api(version).resource(kind, namespace: namespace).get(name)
      rescue K8s::Error::NotFound
        return false
      end
      true
    end

    # get retrieves a resource from the cluster
    def get(name, namespace, kind, version = 'v1')
      @client.api(version).resource(kind, namespace: namespace).get(name)
    end

    # ingress is a just a shortcut get
    def ingress(name, namespace)
      get(name, namespace, 'ingresses', 'extensions/v1beta1')
    end

    # delete removes a resource from the cluster
    def delete(name, namespace, kind, version: 'v1')
      return unless exists?(name, kind, namespace, version)

      @client.api(version).resource(kind, namespace: namespace).delete_resource(name)
    end

    # wait is used to poll until a resource meets the needs of the consumer
    # rubocop:disable Lint/RescueException,Metrics/CyclomaticComplexity,Metrics/AbcSize
    def wait(name, namespace, kind, version: 'v1', max_retries: 60, timeout: 1200, interval: 5, &block)
      retries = counter = 0
      while counter < timeout
        begin
          unless block_given?
            return if exists?(name, kind, namespace, version)

            continue
          end

          resource = @client.api(version).resource(kind).get(name, namespace: namespace)
          return resource if block.call(resource)
        rescue Exception => e
          raise e if retries > max_retries

          retries += 1
        end
        sleep(interval)
        counter += interval
      end

      raise Exception, "operation waiting for #{name}/#{namespace}/#{kind} has failed"
    end
    # rubocop:enable Lint/RescueException,Metrics/CyclomaticComplexity,Metrics/AbcSize

    # kubectl is used to apply a manifest
    # rubocop:disable Metrics/AbcSize
    def kubectl(manifest)
      resource = K8s::Resource.from_json(YAML.safe_load(manifest).to_json)
      raise ArgumentError, 'no api version associated to resource' unless resource.apiVersion
      raise ArgumentError, 'no kind associated to resource' unless resource.kind
      raise ArgumentError, 'no metadata associated to resource' unless resource.metadata
      raise ArgumentError, 'no name associated to resource' unless resource.metadata.name

      name = resource.metadata.name
      namespace = resource.metadata.namespace
      kind = "#{resource.kind.downcase}s"
      version = resource.apiVersion

      return if exists?(name, namespace, kind, version)

      @client.api(version).resource(kind, namespace: namespace).create_resource(resource)
    end
    # rubocop:enable Metrics/AbcSize

    # account returns the credentials for a service account
    def account(name, namespace = 'kube-system')
      sa = @client.api('v1').resource('serviceaccounts', namespace: namespace).get(name)
      secret = @client.api('v1').resource('secrets', namespace: namespace).get(sa.secrets.first.name)
      secret.data.token
    end

    # wait_for_kubeapi is responsible for waiting the api is available
    def wait_for_kubeapi(max_attempts = 60, interval = 5)
      attempts = 0
      while attempts < max_attempts
        begin
          return if @client.api('v1').resource('nodes').list
        rescue StandardError => e
          puts "bad: #{e}"
          attempts += 1
        end
        sleep(interval)
      end
      raise Exception, 'timed out waiting for the kube api'
    end
  end
  # rubocop:enable Metrics/LineLength,Metrics/MethodLength,Metrics/ParameterLists
end
