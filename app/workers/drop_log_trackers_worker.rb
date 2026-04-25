class DropLogTrackersWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform
    LogTracker.where(created_at: ..5.weeks.ago).delete_all
  end
end
