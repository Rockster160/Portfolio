class SimpleFinSyncWorker
  include Sidekiq::Worker

  sidekiq_options retry: 2

  # SimpleFIN is poll-only — there is no push. The Bridge expects ~24 requests
  # a day, and this is not the only caller: SimpleFinBalanceChaseWorker fires
  # up to six more when a charge is expected to move the dashboard figure. Six
  # scheduled runs a day leaves room for both that and a manual
  # `prodExec lib/scripts/sync_simplefin.rb`.
  #
  # Four hours is also honest about the data — the Bridge itself can be a day
  # behind, so polling harder would not make anything fresher. The Chase alert
  # emails remain the real-time signal.
  def perform
    return unless ::SimpleFin::Client.configured?

    result = ::SimpleFin::Refresh.call
    if result.errors.present?
      ::Rails.logger.warn("[SimpleFinSyncWorker] upstream errors: #{result.errors.inspect}")
    end

    ::Rails.logger.info("[SimpleFinSyncWorker] #{result.to_log}")
  end
end
