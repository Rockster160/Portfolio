# Sweeps due BuddyReminders every minute (sidekiq-cron). Idempotent -
# BuddyReminder#pending scope excludes already-fired rows, and
# Buddy::ReminderFirer.fire! double-checks the flags before firing so
# an accidental double-run just no-ops.
class BuddyReminderWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  def perform
    now = Time.current
    BuddyReminder.due(now).find_each { |reminder|
      Buddy::ReminderFirer.fire!(reminder)
    }
  end
end
