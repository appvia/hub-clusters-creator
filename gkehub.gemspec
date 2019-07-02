#!/usr/bin/ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '.', 'lib/gkehub')

require 'version'

# rubocop:disable Metrics/LineLength
Gem::Specification.new do |s|
  s.name        = 'gkehub'
  s.version     = GKE::VERSION
  s.platform    = Gem::Platform::RUBY
  s.date        = '2019-08-02'
  s.authors     = ['Rohith Jayawardene']
  s.email       = 'gambol99@gmail.com'
  s.homepage    = 'http://rubygems.org/gems/gkehub'
  s.summary     = 'An agent used to provision GKE clusters for the Appvia Hub'
  s.description = 'An agent used to provision GKE clusters for the Appvia Hub '
  s.license     = 'GPLV2'
  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map { |f| File.basename(f) }

  s.add_dependency('google-api-client')
  s.add_dependency('googleauth')
  s.add_dependency('k8s-client')
  s.add_dependency('stringio')
end
# rubocop:enable Metrics/LineLength
