class AnoniconsController < ApplicationController

  def index
    @anonicon = Anonicon.generate(request.ip)
  end

  def show
    @anonicon = Anonicon.generate(params[:anon_str] || request.ip)
  end

end
