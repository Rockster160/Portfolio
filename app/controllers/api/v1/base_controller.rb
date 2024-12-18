class Api::V1::BaseController < ApplicationController
  before_action :doorkeeper_authorize!
end
