class AnoniconsController < ApplicationController
  skip_before_filter :verify_authenticity_token

  def index
    @anonicon = Anonicon.generate(request.ip)
  end

  def show
    @anonicon = Anonicon.generate(params[:anon_str] || request.ip)
  end

end
