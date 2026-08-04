# Clears out reminders and watches that are finished with.
#
# Both tables accumulate rows that can never fire again: a one-shot reminder
# that went off, a watch whose expiry has passed, a repeat that ran out its end
# date. None of them show in the panel (every listing scope filters them), so
# nothing was visibly wrong - they just sat there forever, and "the doorbell
# watch is only for today" had no way to actually become true.
#
# Deliberately NOT same-day. A reminder that fired this morning is still worth
# scrolling back to, and a watch someone let expire is worth being able to
# glance at before it goes. RETENTION is the grace period between "can't fire
# again" and "gone".
#
# Idempotent: re-running finds nothing left.
class BuddyReminderSweepWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  # Long enough to answer "did that go off?" the next day, short enough that
  # the list doesn't become an archive.
  RETENTION = 7.days

  def perform
    cutoff = RETENTION.ago
    swept  = {
      fired_reminders:   sweep_reminders(cutoff),
      cancelled_watches: sweep_cancelled_watches(cutoff),
      expired_watches:   sweep_expired_watches(cutoff),
      exhausted_repeats: retire_exhausted_repeats,
    }
    return if swept.values.sum.zero?

    Rails.logger.info("[BuddyReminderSweep] #{swept.map { |k, v| "#{k}=#{v}" }.join(" ")}")
  end

  private

  # Terminal means fired (one-shot) or cancelled. A recurring reminder never
  # sets `fired_at`, so it's never caught here however long it's been running.
  def sweep_reminders(cutoff)
    BuddyReminder
      .where("fired_at IS NOT NULL AND fired_at <= :cutoff", cutoff: cutoff)
      .or(BuddyReminder.where("cancelled_at IS NOT NULL AND cancelled_at <= :cutoff", cutoff: cutoff))
      .delete_all
  end

  def sweep_cancelled_watches(cutoff)
    BuddyWatch.where("cancelled_at IS NOT NULL AND cancelled_at <= ?", cutoff).delete_all
  end

  # A one-shot that fired is done; so is anything past its expiry. The expiry
  # is the whole point of this worker - a repeating watch bounded to "today"
  # has nothing else that would ever retire it.
  def sweep_expired_watches(cutoff)
    BuddyWatch
      .where("fired_at IS NOT NULL AND fired_at <= :cutoff", cutoff: cutoff)
      .or(BuddyWatch.where("expires_at IS NOT NULL AND expires_at <= :cutoff", cutoff: cutoff))
      .delete_all
  end

  # A recurring reminder whose end date has passed can't produce another
  # occurrence, but nothing marks it - `pending` is "not fired, not cancelled",
  # and a repeat never sets `fired_at`. Stamping it moves it out of the live
  # list and into the grace period above, where the next sweep collects it.
  def retire_exhausted_repeats
    scope = BuddyReminder.pending.where.not(recurrence: nil)
    scope.find_each.count { |reminder|
      next false if reminder.next_fire_at.present?

      reminder.update!(fired_at: Time.current)
      true
    }
  end
end
