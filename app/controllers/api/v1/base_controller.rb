class Api::V1::BaseController < ApplicationController
  before_action :doorkeeper_authorize!
  respond_to :json
end
