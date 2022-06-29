class DashboardController < ApplicationController
  before_action :authorize_admin

  def show
    @skip_dark_mode = true
  end

  def octoprint_session
    # render text: json[:session]
  end
end
