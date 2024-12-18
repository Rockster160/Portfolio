class Api::V1::BaseController < ApplicationController
  before_action :doorkeeper_authorize!
  before_action -> { request.format = :json }
end
