class DropLogTrackersWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  RETENTION = 5.weeks
  BATCH_SIZE = 5_000

  def perform
    LogTracker.where(created_at: ..RETENTION.ago).in_batches(of: BATCH_SIZE).delete_all
  end
end
