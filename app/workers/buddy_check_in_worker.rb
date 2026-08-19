# Asks about one thing Buddy noted to come back to.
#
# Scheduled per-record with `perform_at` rather than swept by a cron. A check-in
# has a specific moment attached, so there is nothing for a periodic job to
# discover — and a minute-by-minute sweep for something that fires a handful of
# times a month is exactly the shape this codebase avoids elsewhere.
#
# Times move: a re-plan can push a check-in back when a weightier one arrives,
# and the fire-time gate can push it past a live conversation. So the job
# re-reads `check_in_at` and reschedules itself when it has drifted, the same
# way BuddyCompileWorker and TimerFireWorker do. No jids are tracked and nothing
# is cancelled; a stale job finds a record that no longer wants asking about and
# exits.
class BuddyCheckInWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform(memory_id)
    memory = BuddyMemory.find_by(id: memory_id)
    return if memory.nil?

    due_at = memory.check_in_at
    return if due_at.nil?

    # Its time moved after this job was queued. Exit rather than rescheduling:
    # whatever moved it enqueued a job for the new time (Buddy::CheckIns owns
    # every enqueue), so one already exists.
    return if due_at > Time.current

    Buddy::CheckIns.fire!(memory)
  end
end
