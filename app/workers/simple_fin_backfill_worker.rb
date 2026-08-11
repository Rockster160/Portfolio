class SimpleFinBackfillWorker
  include Sidekiq::Worker

  # No retry: the next scheduled run is three hours away and picks up from the
  # same cursor, so there is nothing a retry recovers that it does not — and a
  # retry storm would spend requests from a budget the scheduled sync and the
  # chase job draw on too.
  sidekiq_options retry: false

  def perform
    result = ::SimpleFin::Backfill.call
    ::Rails.logger.info("[SimpleFinBackfillWorker] #{result.to_log}")
  end
end
