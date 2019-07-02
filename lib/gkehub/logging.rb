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

require 'colorize'

module GKE
  # Logging is few helper functions for logging
  module Logging
    def info(string, options = {})
      print formatted_string("[info] #{dated_string(string)}", options)
    end

    def warn(string)
      Kernel.warn formatted_string(string, symbol: '*', color: :orange)
    end

    def error(string)
      Kernel.warn formatted_string(string, symbol: '!', color: :red)
    end

    private

    def dated_string(string)
      "[#{Time.now}] #{string}"
    end

    def formatted_string(string, options = {})
      return unless @logging

      symbol = options[:symbol] || ''
      string = string.to_s
      string = string.colorize(options[:color]) if options[:color]
      "#{symbol}#{string}\n"
    end
  end
end
