# The daily sweep for `/q` sessions: each one its owner hasn't replied to in
# FeatureBuilder::Quick::IDLE_AFTER is closed, its pane on the Mini with it.
class QuickCloseWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  def perform
    FeatureBuilder::Quick.close_idle!
  end
end
