# rubocop:disable Naming/FileName
# frozen_string_literal: true

#
# rubocop:enable Naming/FileName
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

require_relative 'hub-clusters-creator/agent'
require_relative 'hub-clusters-creator/version'

# Clusters providers the wrapper to the providers
module HubClustersCreator
  def self.version
    HubClustersCreator::VERSION
  end

  def self.new(name)
    HubClustersCreator::Agent.new(name)
  end

  def self.defaults(name)
    HubClustersCreator::Agent.defaults(name)
  end

  def self.schema
    o = []
    HubClustersCreator::Agent.providers.each do |x|
      o.push(
        id: x,
        init_options: HubClustersCreator::Agent.provider_schema(x),
        provision_options: HubClustersCreator::Agent.cluster_schema(x)
      )
    end
    o
  end
end
