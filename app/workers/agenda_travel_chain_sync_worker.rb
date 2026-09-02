# Recomputes the travel chain for one user's perceived day. Enqueued by the
# AgendaItem after_save_commit / after_destroy_commit callback when a
# chain-relevant field actually changes; coalesces fast bursts (drag-storms,
# bulk imports) into a single recompute via the Sidekiq-Cron `unique_for`
# semantics.
class AgendaTravelChainSyncWorker
  include Sidekiq::Worker

  # Coalesces multiple enqueues with the same args so a drag-storm of 20 saves
  # on the same day collapses to a single recompute.
  #
  # `until_executing`, NOT `until_executed`, and the difference is a whole class
  # of wrong times. This job recomputes to whatever the row says WHEN IT RUNS,
  # so a lock that outlives the start of execution throws away any edit that
  # lands mid-run: the enqueue is coalesced into a job that has already read the
  # old row, and nothing recomputes it afterwards. `until_executing` releases at
  # the moment work begins, so a change arriving during the run books a fresh
  # pass over the new state.
  #
  # Prod, both moved and both left holding a leave_at computed for their old
  # start: agenda_items 1069 (Orchard, moved by the Buddy tool on 1 Sep, leave_at
  # 34 seconds AFTER its own start) and 1048 ("IT", moved by a PATCH from the UI
  # on 29 Aug, leave_at a clean 24 hours early). Two different writers, one
  # pipeline - which is why this is fixed here and not in either of them.
  # `Buddy::Context#leave_by` and `AgendaBriefing#travel_line` read that field
  # verbatim, so a stale value is quoted to the person as fact.
  sidekiq_options retry: 1, lock: :until_executing

  def perform(user_id, date_iso)
    user = ::User.find_by(id: user_id)
    return unless user

    date = ::Date.iso8601(date_iso)
    ::AgendaTravelChain.run_for(user, date)
  end
end
