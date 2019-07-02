# frozen_string_literal: true

require 'k8s-client'

module GKE
  # Kube is a collection of methods for interacting with the kubernetes api
  class Kube
    def initialize(endpoint, token)
      @endpoint = "https://#{endpoint}" unless endpoint.start_with?('https')
      @token = token
      @client = K8s.client(
        ("https://#{endpoint}" unless endpoint.start_with?('https')),
        auth_token: token,
        ssl_verify_peer: false
      )
    end

    # kubectl is used to apply a manifest
    # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/LineLength
    def kubectl(manifest)
      resource = K8s::Resource.from_json(YAML.safe_load(manifest).to_json)
      raise ArgumentError, 'no api version associated to resource' unless resource.apiVersion
      raise ArgumentError, 'no kind associated to resource' unless resource.kind
      raise ArgumentError, 'no metadata associated to resource' unless resource.metadata
      raise ArgumentError, 'no name associated to resource' unless resource.metadata.name

      name = resource.metadata.name
      kind = resource.kind.downcase
      version = resource.apiVersion

      # @step: check if the resource exists
      begin
        @client.api(version).resource("#{kind}s", namespace: resource.metadata.namespace).get(name)
      rescue K8s::Error::NotFound
        @client.api(version).resource("#{kind}s", namespace: resource.metadata.namespace).create_resource(resource)
      end
    end

    # service_account returns the credentials for a service account
    def service_account(name, namespace = 'kube-system')
      sa = @client.api('v1').resource('serviceaccounts', namespace: namespace).get(name)
      secret = @client.api('v1').resource('secrets', namespace: namespace).get(sa.secrets.first.name)
      secret.data.token
    end

    # hold_for_kubeapi is responsible for waiting the api is available
    def hold_for_kubeapi
      max_attempts = 60
      attempts = 0

      # @step: wait for the api to be available
      loop do
        begin
          break if @client.api('v1').resource('nodes').list
        rescue StandardError
          attempts += 1
          sleep(5)
          raise Exception, 'timed out waiting for the api' if attempts >= max_attempts
        end
      end
    end
    # rubocop:enable Metrics/AbcSize,Metrics/MethodLength,Metrics/LineLength
  end
end
