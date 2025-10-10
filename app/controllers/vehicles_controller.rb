class VehiclesController < ApplicationController
  skip_before_action :verify_authenticity_token
  def command
    head :unauthorized
  end

  def token
    head :ok
  end
end
