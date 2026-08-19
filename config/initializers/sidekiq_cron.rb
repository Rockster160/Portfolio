return if ENV["RAILS_CONSOLE"] == "true"
return if ENV["LOCAL_QUEUE"] == "true"
# `defined?(Puma)` does NOT mean "running under Puma" — Bundler.require loads
# the gem in every process, rake tasks included, so this guard has never
# excluded anything. Kept because it still rules out environments where the
# gem genuinely is absent.
return unless defined?(Puma)

# The one that actually catches `rake db:migrate`. Registering the whole cron
# schedule as a side effect of a migration is surprising locally, and on a
# deploy it means the release being swapped in re-registers every job from a
# task rather than from the server that will run them.
# `respond_to?` guard because `Rake` can be a partially-loaded module — under
# RSpec it is defined without `.application` at all.
if defined?(::Rake) && ::Rake.respond_to?(:application)
  return if ::Rake.application.top_level_tasks.present?
end
return if Rails.env.test?
return if Rails.const_defined?("Console")
return if Rails.const_defined?("Rails::Command::RunnerCommand")

# return unless Rails.env.production?

# Based on UTC time
every_minute = "* * * * *"
every_5_minutes = "*/5 * * * *"
every_hour = "0 * * * *"
every_4_hours = "0 */4 * * *"
every_3_daylight_hours = "0 5-21/3 * * * MST"
daily_3am = "0 3 * * * MST"
# :37 rather than :00 — the Bridge asks that requests be staggered off the
# hour, and the 4-hourly sync already owns that slot.
every_3_hours_staggered = "37 */3 * * *"
daily_4am = "0 4 * * * MST"
# Keep in step with ByteDailyAudit::BACKSTOP_HOUR — that's the constant the
# audit's own "have I waited long enough" check reads.
daily_10am = "0 10 * * * MST"
daily_9pm = "0 21 * * * MST"
thursdays_at_noon = "0 12 * * 4 MST"
mondays_at_noon = "0 12 * * 1 MST"
monthly_5th_at_11am = "0 11 5 * * MST"
monthly_1st_at_midnight = "0 0 1 * * MST"

cron_jobs = [
  {
    # Guest accounts and one-off IPs, swept together. 9pm rather than the 4am
    # slot on purpose — that hour already runs four jobs against a Sidekiq
    # concurrency of 5.
    name:  "Forget One-Off Visitors",
    class: "CleanVisitorsWorker",
    cron:  daily_9pm,
  },
  {
    name:  "Trigger Jil Cron",
    class: "JilScheduleWorker",
    cron:  every_minute,
  },
  {
    name:  "Fire Due Agenda Triggers",
    class: "FireDueAgendaTriggersWorker",
    cron:  every_minute,
  },
  {
    name:  "Send Due Agenda Notifications",
    class: "SendDueAgendaNotificationsWorker",
    cron:  every_minute,
  },
  {
    name:  "Fire Due Buddy Reminders",
    class: "BuddyReminderWorker",
    cron:  every_minute,
  },
  {
    name:  "Rest Buddy's Face After A Lull",
    class: "BuddyExpressionResetWorker",
    cron:  every_minute,
  },
  {
    name:  "Prune Expired Buddy Memories",
    class: "BuddyMemoryPruneWorker",
    cron:  daily_4am,
  },
  {
    name:  "Sweep Finished Buddy Reminders And Watches",
    class: "BuddyReminderSweepWorker",
    cron:  daily_4am,
  },
  {
    name:  "Google Calendar Sync Fallback",
    class: "GoogleCalendarSyncWorker",
    cron:  every_5_minutes,
  },
  {
    name:  "Google Calendar Watch Renewal",
    class: "GoogleCalendarWatchRenewalWorker",
    cron:  every_hour,
  },
  {
    name:  "Chores Daily Reset",
    class: "ChoreDailyResetWorker",
    cron:  daily_4am,
  },
  {
    name:  "Purge Unclaimed Uploads",
    class: "ActiveStorageSweepWorker",
    cron:  daily_4am,
  },
  {
    # Hourly rather than daily: the gap between "they're not going to answer"
    # and being told is the whole cost here, and it's already three days.
    name:  "Close Out Unanswered Buddy Questions",
    class: "BuddyAwaitSweepWorker",
    cron:  every_hour,
  },
  {
    # Deliberately off the 4am slot — that hour already runs four jobs against
    # a Sidekiq concurrency of 5.
    name:  "Archive Aged Executions",
    class: "ExecutionArchiveWorker",
    cron:  daily_3am,
  },
  {
    # SimpleFIN is poll-only and budgets ~24 requests/day. Six scheduled runs
    # leaves room for SimpleFinBalanceChaseWorker (up to six more, only when a
    # charge is expected to move the dashboard figure) and a manual run.
    name:  "Sync SimpleFIN Balances And Transactions",
    class: "SimpleFinSyncWorker",
    cron:  every_4_hours,
  },
  {
    # Eight historical windows a day, walking backwards until the history runs
    # out — about a week to cover seven years, where one a day would have taken
    # seven weeks.
    #
    # The budget takes it: 6 scheduled syncs + up to 4 chases + 8 here is 18 of
    # the Bridge's 24, worst case, leaving room for a manual run. Spread rather
    # than burst on purpose — the quota replenishes through the day, so eight
    # requests three hours apart sit far more comfortably than eight at once.
    #
    # Costs nothing once the walk is finished: it returns :done without making
    # a request.
    name:  "Backfill SimpleFIN History",
    class: "SimpleFinBackfillWorker",
    cron:  every_3_hours_staggered,
  },
  {
    # The BACKSTOP, not the usual path. Ordinarily the audit is enqueued the
    # moment the morning Today finishes writing (Buddy::GPT::Turn
    # #queue_daily_audit), so the report lands directly under the briefing.
    # This covers the day Today never came — asleep, no conversation, Sidekiq
    # backed up — and is a no-op on every other day, because run! is guarded by
    # `already_ran?`. Reviews the 24 hours ending whenever it runs; see
    # ByteDailyAudit#window.
    name:  "Daily Byte Audit Backstop",
    class: "DailyAuditWorker",
    cron:  daily_10am,
  },
]

if Rails.env.production?
  cron_jobs += [
    # Blocked on pg_stat_statements: the extension is installed but the
    # library has never been in shared_preload_libraries, so PgHero has
    # nothing to capture. Uncomment once the postgresql.conf block at the
    # repo root has been applied and Postgres restarted.
    # {
    #   name: "CaptureQueryStats",
    #   class: "CaptureQueryStatsWorker",
    #   cron: every_5_minutes,
    # },
    {
      name:  "DropLogTrackers",
      class: "DropLogTrackersWorker",
      cron:  daily_4am,
    },
  ]
elsif Rails.env.development?
  cron_jobs += [
    # {
    #   name: "ReloadTeslaLocal",
    #   class: "ReloadTeslaLocalWorker",
    #   cron: every_3_daylight_hours,
    # },
  ]
end

if Rails.env.development?
  Rails.application.reloader.to_prepare do
    Sidekiq::Cron::Job.load_from_array!(cron_jobs)
  end
else
  Sidekiq::Cron::Job.load_from_array!(cron_jobs)
end
