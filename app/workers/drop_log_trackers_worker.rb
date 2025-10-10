class DropLogTrackersWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform
    LogTracker.where(created_at: ..1.month.ago).destroy_all
  end
end
