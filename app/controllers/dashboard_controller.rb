class DashboardController < ApplicationController
  before_action :authorize_admin

  def show
  end

  def octoprint_session
    response = RestClient.post(
      "http://zoro-pi-1.local/api/login",
      { passive: true },
      { "X-Api-Key": ""}
    )
    json = JSON.parse(response, symbolize_names: true)

    render text: json[:session]
  end
end
