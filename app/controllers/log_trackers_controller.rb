class LogTrackersController < ApplicationController
  before_action :authorize_admin

  def index
    @loggers = LogTracker.not_me.not_log_tracker.order(created_at: :desc).page(params[:page])
    @loggers = @loggers.by_fuzzy_url(params[:fuzzy_url]) if params[:fuzzy_url].present?
  end

  def show
    @logger = LogTracker.find(params[:id])
  end

end
