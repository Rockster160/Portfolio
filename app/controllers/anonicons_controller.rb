class AnoniconsController < ApplicationController
  skip_before_filter :verify_authenticity_token

  def index
    @anonicon = Anonicon.generate(params[:anon_str] || request.ip)

    if request.xhr?
      render partial: "show"
    end
  end

  def show
    anonicon_source = params[:id] || request.ip
    @anonicon = Anonicon.generate(anonicon_source)

    send_data @anonicon.raw.to_blob, type: "image/png", disposition: "inline", stream: true
  end

end
