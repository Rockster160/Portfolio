# Deletes expired short-term BuddyMemories (those with a past `expires_at`).
# Durable facts (null `expires_at`) are never touched here - they only leave
# via an explicit [[forget]] or deliberate curation. Idempotent: re-running
# just finds nothing left to delete.
class BuddyMemoryPruneWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  def perform
    deleted = BuddyMemory.where("expires_at IS NOT NULL AND expires_at <= ?", Time.current).delete_all
    Rails.logger.info("[BuddyMemoryPrune] pruned #{deleted} expired memories") if deleted.positive?
  end
end
