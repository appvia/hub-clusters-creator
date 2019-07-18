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

creator = Clusters.new(
  client_id: ENV['AKS_CLIENT_ID'],
  client_secret: ENV['AKS_CLIENT_SECRET'],
  provider: 'aks',
  region: 'uksouth',
  subscription: ENV['AKS_SUBSCRIPTION'],
  tenant: ENV['AKS_TENANT']
)
puts creator.provision(
  description: 'just a test',
  domain: 'akslearning.appvia.io',
  github_client_id: ENV['GITHUB_CLIENT_ID'],
  github_client_secret: ENV['GITHUB_CLIENT_SECRET'],
  github_organization: ENV['GITHUB_ORG'],
  grafana_hostname: 'grafana.akslearning.appvia.io',
  size: 3,
  ssh_key: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB/RZqb2UuuXmJbwml/G1InXVwgNe1tgz+Xd6HTfPlS00GSHTynjyLNKWbDBZhzj2jsM/40TyCZLLKai8hV4Lc72ijMsEAbSJ8gou0Kq6P25GxY7uQcCeACPT6AbQCZjiyzPCFPy+QC56W64QOtS+SLRefY8g4uGAz01ZfhChK0J2Mev1oiPXRAlOmzGz9fPpx4J8YE0R/OkEoWQaWdKVOV6nq2nz3vbwvLfbdK0EK/KAivwv9mlgalwSr3bgAXwRS2nXq7vyITvpjgDYcRu85fWSE9yeMyw4S10ya5/ALi+p4HkSbDaz2YGwksSup1lBeRflSKKghWba4+dzf4iO87cwYCN8erVxATznuPoB0TWYYOXrUwc3yGadOV5GkzQLLDhIzJ8BmMb/iT5jHBdHs1bK1lTThwPllmgkRANFIWMC9jyA3BgJp2vtHcLyOXOsFFaXqpjXZ2tvjaBVjaaDUY+CE2rbJMBquUMbvtxwBtkhVVQ4COofUsXhKOcwjOyo1Hw1hcJ9ig6DiuzYhiPr/JZPUk2l8ovAKkGwFjEui7jltcWzGrmRzFp8+Xdq9wl/BEeglPv+eZuuwXgAWRge992kepda1f5OlBUl8JrohbxtVcv+zvmVaiZqcrKpyNbtN0ELMA8e4K6wCllQ0oBr17oTG7JwMVgfvTCgsI+U/ jest@starfury',
  name: 'dev',
  version: '1.14.3'
)
