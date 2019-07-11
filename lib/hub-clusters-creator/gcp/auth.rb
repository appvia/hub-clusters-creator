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

module GCP
  # Auth provides authentication to GCP
  module Auth
    private

    # authorize is responsible for providing an access token to operate
    def authorize(scopes = ['https://www.googleapis.com/auth/cloud-platform'])
      if @authorizer.nil?
        @authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(@account),
          scope: scopes
        )
        @authorizer.fetch_access_token!
      end
      @authorizer
    end
  end
end
