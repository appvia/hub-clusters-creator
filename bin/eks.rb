#!/bin/ruby
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
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '.', '../lib')

require 'hub-clusters-creator'
require 'pp'

creator = HubClustersCreator.new(
  provider: 'eks',
  access_id: ENV['EKS_ACCESS_ID'],
  access_key: ENV['EKS_ACCESS_KEY'],
  account_id: ENV['EKS_ACCOUNT_ID'],
  region: ENV['EKS_REGION']
)
puts creator.provision(
  domain: 'ekslearning.appvia.io',
  github_client_id: ENV['GITHUB_CLIENT_ID'],
  github_client_secret: ENV['GITHUB_CLIENT_SECRET'],
  github_organization: ENV['GITHUB_ORG'],
  grafana_hostname: 'grafana',
  grafana_ingress: true,
  machine_type: 't3.medium',
  name: 'test',
  size: 3,
  ssh_keypair: 'default',
  version: '1.13'
)
