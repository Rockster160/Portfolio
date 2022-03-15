class DashboardController < ApplicationController
  before_action :authorize_admin

  def show
  end

  def octoprint_session
    # render text: json[:session]
  end
end
