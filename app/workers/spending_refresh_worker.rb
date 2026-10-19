# Re-reads the Spending cell's figures and repaints it when they moved.
class SpendingRefreshWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 0

  def perform
    ::SpendingHealth.refresh!
  end
end
