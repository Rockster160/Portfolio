# Activity rows past BuddyActivity::RETAIN_FOR.
class BuddyActivitySweepWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  BATCH_SIZE = 5_000

  def perform
    BuddyActivity.expired.in_batches(of: BATCH_SIZE).delete_all
  end
end
