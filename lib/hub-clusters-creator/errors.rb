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

# rubocop:disable Metrics/LineLength
module HubClustersCreator
  # Errors is collection of custom errors and exceptions
  module Errors
    # InfrastructureError defines an error occurred creating or configuring the cluster
    class InfrastructureError < StandardError
      def initialize(msg = 'failed attempting to create the cluster')
        super(msg)
      end
    end

    # ConfigurationError defines an error related to configuration
    class ConfigurationError < StandardError
      attr_accessor :field, :value

      def initialize(msg = 'invalid configuration', field:, value:)
        @field = field
        @value = value
        super(msg)
      end
    end

    # InitializerError is thrown when we've encountered an error attempting to bootstrap cluster
    class InitializerError < StandardError
      def initialize(msg = 'failed attempting to bootstrap the cluster')
        super(msg)
      end
    end
  end
end
# rubocop:enable Metrics/LineLength
