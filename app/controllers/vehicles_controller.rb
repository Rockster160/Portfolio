class VehiclesController < ApplicationController
  skip_before_action :verify_authenticity_token
  def command
    head 401
  end

  def token
    head 200
  end
end
