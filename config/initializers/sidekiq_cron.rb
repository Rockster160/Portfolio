return if ENV["RAILS_CONSOLE"] == "true"
return if ENV["LOCAL_QUEUE"] == "true"
return unless defined?(Puma)
return if Rails.env.test?
return if Rails.const_defined?("Console")
return if Rails.const_defined?("Rails::Command::RunnerCommand")
return unless Rails.env.production?

# Based on UTC time
every_minute = "* * * * *"
every_5_minutes = "*/5 * * * *"
every_hour = "0 * * * *"
every_3_daylight_hours = "0 5-21/3 * * * MST"
daily_9pm = "0 3 * * *"
thursdays_at_noon = "0 18 * * 4"
mondays_at_noon = "0 18 * * 1"
monthly_5th_at_11am = "0 17 5 * *"
monthly_1st_at_midnight = "0 6 1 * *"

cron_jobs = [
  {
    name:  "Clean up Guests",
    class: "CleanGuestsWorker",
    cron:  daily_9pm,
  },
  {
    name:  "Reschedule Items",
    class: "RescheduleItemsWorker",
    cron:  every_minute,
  },
  {
    name:  "Trigger Jil Cron",
    class: "JilScheduleWorker",
    cron:  every_minute,
  },
]

if Rails.env.production?
  cron_jobs += [
    # {
    #   name: "CaptureQueryStats",
    #   class: "CaptureQueryStatsWorker",
    #   cron: every_5_minutes,
    # },
    {
      name:  "DropLogTrackers",
      class: "DropLogTrackersWorker",
      cron:  monthly_1st_at_midnight,
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
