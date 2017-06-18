class AnoniconsController < ApplicationController
  skip_before_filter :verify_authenticity_token

  def index
    @anonicon = Anonicon.generate(params[:anon_str] || request.ip)

    if request.xhr?
      render partial: "show"
    end
  end

end
