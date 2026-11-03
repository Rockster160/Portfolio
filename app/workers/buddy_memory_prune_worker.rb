# Deletes expired short-term BuddyMemories (those with a past `expires_at`).
# Durable facts (null `expires_at`) are never touched here - they only leave
# via an explicit [[forget]] or deliberate curation. Idempotent: re-running
# just finds nothing left to delete.
class BuddyMemoryPruneWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  def perform
    # destroy, not delete: a memory's notes hold a foreign key to it, and one
    # noted memory would roll the whole statement back.
    expired = BuddyMemory.where("expires_at IS NOT NULL AND expires_at <= ?", Time.current)
    deleted = expired.destroy_all.size
    Rails.logger.info("[BuddyMemoryPrune] pruned #{deleted} expired memories") if deleted.positive?
  end
end
