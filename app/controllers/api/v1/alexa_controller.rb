class Api::V1::AlexaController < Api::V1::BaseController
  before_action :doorkeeper_authorize!
  respond_to :json

  def alexa
    head :ok
  end
end
