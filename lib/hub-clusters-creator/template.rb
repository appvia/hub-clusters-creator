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

require 'erb'

module Clusters
  module Utils
    # Template is a collection of erb template
    module Template
      # Render is a class for templating
      class Render
        attr_accessor :context

        def initialize(context)
          @context = context
        end

        def render(template)
          ERB.new(template, nil, '-').result(get_binding)
        end

        # rubocop:disable Naming/AccessorMethodName
        def get_binding
          binding
        end
        # rubocop:enable Naming/AccessorMethodName
      end
    end
  end
end
