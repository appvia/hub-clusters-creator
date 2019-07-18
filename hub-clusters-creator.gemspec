#!/usr/bin/ruby
# frozen_string_literal: true

# rubocop:disable Metrics/LineLength
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '.', 'lib/hub-clusters-creator')

require 'version'

Gem::Specification.new do |s|
  s.name        = 'hub-clusters-creator'
  s.version     = Clusters::VERSION
  s.platform    = Gem::Platform::RUBY
  s.date        = '2019-08-02'
  s.authors     = ['Rohith Jayawardene']
  s.email       = 'gambol99@gmail.com'
  s.homepage    = 'http://rubygems.org/gems/hub-clusters-creator'
  s.summary     = 'An agent used to provision GKE clusters for the Appvia Hub'
  s.description = 'An agent used to provision GKE clusters for the Appvia Hub '
  s.license     = 'GPL-2.0'
  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map { |f| File.basename(f) }

  s.add_dependency('azure_mgmt_container_service', '~> 0.18.5')
  s.add_dependency('azure_mgmt_dns', '~> 0.18.5')
  s.add_dependency('azure_mgmt_resources', '~> 0.18.5')
  s.add_dependency('deep_merge', '~> 1.2.1')
  s.add_dependency('google-api-client', '~> 0.30')
  s.add_dependency('googleauth', '~> 0.7')
  s.add_dependency('json_schema', '~> 0.20.4')
  s.add_dependency('k8s-client', '~> 0.10')
  s.add_dependency('stringio', '~> 0.0.2')
end
# rubocop:enable Metrics/LineLength
