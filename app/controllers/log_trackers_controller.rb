class LogTrackersController < ApplicationController
  skip_before_action :tracker
  before_action :authorize_admin

  def index
    @loggers = LogTracker.all
    @loggers = @loggers.query(params[:q]) if params[:q].present?
    @loggers = @loggers.order(created_at: :desc).page(params[:page])
  end

  def show
    @logger = LogTracker.find(params[:id])
  end

  def ban
    BannedIp.find_or_create_by(ip: params[:ip])

    redirect_back fallback_location: :log_trackers
  end
end
