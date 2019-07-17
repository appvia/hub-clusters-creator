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
module Clusters
  def self.version
    Clusters::VERSION
  end

  def self.new(provider)
    Clusters::Agent.new(provider)
  end

  def self.defaults(provider)
    Clusters::Agent.defaults(provider)
  end

  def self.providers
    Clusters::Agent.providers
  end

  def self.schema(provider)
    Clusters::Agent.schema(provider)
  end

  def self.provider?(name)
    Clusters::Agent.provider?(name)
  end
end
