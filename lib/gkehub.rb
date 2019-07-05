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

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), 'gkehub/')
require 'agent'

module GKE
  # Provision is a wrapper to the agent
  module Provision
    ROOT = __dir__
    require "#{ROOT}/gkehub/version"

    def self.version
      GKE::VERSION
    end

    def self.new(account, project, region, logging = false)
      GKE::Agent.new(account, project, region, logging)
    end
  end
end
