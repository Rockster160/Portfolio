# Recomputes the travel chain for one user's perceived day. Enqueued by the
# AgendaItem after_save_commit / after_destroy_commit callback when a
# chain-relevant field actually changes; coalesces fast bursts (drag-storms,
# bulk imports) into a single recompute via the Sidekiq-Cron `unique_for`
# semantics.
class AgendaTravelChainSyncWorker
  include Sidekiq::Worker

  # `lock: :until_executed` coalesces multiple enqueues with the same args
  # while a job is queued/running. A drag-storm of 20 saves on the same day
  # collapses to a single recompute.
  sidekiq_options retry: 1, lock: :until_executed

  def perform(user_id, date_iso)
    user = ::User.find_by(id: user_id)
    return unless user

    date = ::Date.iso8601(date_iso)
    ::AgendaTravelChain.run_for(user, date)
  end
end
