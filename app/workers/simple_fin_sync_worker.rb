class SimpleFinSyncWorker
  include Sidekiq::Worker

  sidekiq_options retry: 2

  # SimpleFIN is poll-only — there is no push. The Bridge expects ~24 requests
  # a day, so this runs every two hours: twelve, leaving headroom for a manual
  # `prodExec lib/scripts/sync_simplefin.rb` without blowing the budget.
  #
  # Two hours is also honest about the data. The Bridge itself can be up to a
  # day behind, so polling harder would not make anything fresher — the Chase
  # alert emails remain the real-time signal.
  WINDOW_DAYS = 14

  def perform
    return unless ::SimpleFin::Client.configured?

    result = ::SimpleFin::Sync.run!(start_date: WINDOW_DAYS.days.ago)
    if result.errors?
      ::Rails.logger.warn("[SimpleFinSyncWorker] upstream errors: #{result.errors.inspect}")
    end

    match = ::SimpleFin::EventMatcher.call
    transfers = ::SimpleFin::TransferDetector.call

    ::Rails.logger.info(
      "[SimpleFinSyncWorker] accounts=#{result.accounts} transactions=#{result.transactions} " \
      "linked=#{match.linked} ambiguous=#{match.ambiguous} transfers=#{transfers.paired}",
    )
  end
end
