return if ENV["RAILS_CONSOLE"] == "true"
return if ENV["LOCAL_QUEUE"] == "true"
return unless defined?(Puma)
return if Rails.env.test?
return if Rails.const_defined?("Console")
return if Rails.const_defined?("Rails::Command::RunnerCommand")

# return unless Rails.env.production?

# Based on UTC time
every_minute = "* * * * *"
every_5_minutes = "*/5 * * * *"
every_hour = "0 * * * *"
every_3_daylight_hours = "0 5-21/3 * * * MST"
daily_3am = "0 3 * * * MST"
daily_4am = "0 4 * * * MST"
daily_9pm = "0 21 * * * MST"
thursdays_at_noon = "0 12 * * 4 MST"
mondays_at_noon = "0 12 * * 1 MST"
monthly_5th_at_11am = "0 11 5 * * MST"
monthly_1st_at_midnight = "0 0 1 * * MST"

cron_jobs = [
  {
    name:  "Clean up Guests",
    class: "CleanGuestsWorker",
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
    name:  "Fire Scheduled Buddy Today Briefing",
    class: "BuddyTodayWorker",
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
