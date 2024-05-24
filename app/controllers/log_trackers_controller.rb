class LogTrackersController < ApplicationController
  skip_before_action :tracker
  before_action :authorize_admin

  def index
    @loggers = LogTracker.order(created_at: :desc).page(params[:page])
    @loggers = @loggers.query(params[:q]) if params[:q].present?
  end

  def show
    @logger = LogTracker.find(params[:id])
  end

end
