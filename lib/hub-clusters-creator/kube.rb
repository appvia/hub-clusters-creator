# frozen_string_literal: true

require 'k8s-client'

module GKE
  # Kube is a collection of methods for interacting with the kubernetes api
  # rubocop:disable Metrics/LineLength,Metrics/MethodLength,Metrics/ParameterLists
  class Kube
    attr_accessor :endpoint, :token

    def initialize(endpoint, token)
      raise ArgumentError, 'you have not specified an access token' unless token
      raise ArgumentError, 'you have not specified an endpoint' unless endpoint

      @endpoint = "https://#{endpoint}" unless endpoint.start_with?('https')
      @token = token
      @client = K8s.client(
        @endpoint,
        auth_token: @token,
        ssl_verify_peer: false
      )
    end

    # exists? checks if the resource exists
    def exists?(name, kind, namespace = 'default', version = 'v1')
      begin
        kind = "#{kind}s" unless kind.end_with?('s')
        @client.api(version).resource(kind, namespace: namespace).get(name)
      rescue K8s::Error::NotFound
        return false
      end
      true
    end

    # get retrieves a resource from the cluster
    def get(name, namespace, kind, version: 'v1')
      @client.api(version).resource(kind, namespace: namespace).get(name)
    end

    # delete removes a resource from the cluster
    def delete(name, kind, namespace, version: 'v1')
      return unless exists?(name, kind, namespace, version)

      @client.api(version).resource(kind, namespace: namespace).delete_resource(name)
    end

    # wait is used to poll until a resource meets the needs of the consumer
    # rubocop:disable Lint/RescueException,Metrics/CyclomaticComplexity,Metrics/AbcSize
    def wait(name, namespace, kind, version: 'v1', max_retries: 50, timeout: 300, interval: 5, &block)
      retries = counter = 0
      while counter < timeout
        begin
          unless block_given?
            return if exists?(name, kind, namespace, version)

            continue
          end

          resource = @client.api(version).resource(kind).get(name, namespace: namespace)
          return if block.call(resource)
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
      kind = resource.kind.downcase
      version = resource.apiVersion
      return if exists?(name, kind, namespace, version)

      @client.api(version).resource("#{kind}s", namespace: namespace).create_resource(resource)
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
        rescue StandardError
          attempts += 1
        end
        sleep(interval)
      end
      raise Exception, 'timed out waiting for the kube api'
    end
  end
  # rubocop:enable Metrics/LineLength,Metrics/MethodLength,Metrics/ParameterLists
end
