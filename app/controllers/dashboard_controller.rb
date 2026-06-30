class DashboardController < ApplicationController
  before_action :authorize_admin, except: :demo

  def show
    @skip_dark_mode = true
    @isolated_cell = params[:cell].to_s.downcase.gsub(/[^a-z]/, "").presence
  end

  def octoprint_session
    # render text: json[:session]
  end
end
