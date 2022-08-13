return if Rails.env.test?
# Based on UTC time
every_minute = "* * * * *"
every_hour = "0 * * * *"
daily_9pm = "0 3 * * *"
thursdays_at_noon = "0 18 * * 4"
monthly_5th_at_11am = "0 17 5 * *"
monthly_15th_at_2pm = "0 20 15 * *"

cron_jobs = [
  {
    name: "Clean up Guests",
    class: "CleanGuestsWorker",
    cron: daily_9pm
  },
  {
    name: "Reschedule Items",
    class: "RescheduleItemsWorker",
    cron: every_minute
  },
]

if Rails.env.production?
  cron_jobs += [
    {
      name: "HourlyVenmoCheck",
      class: "HourlyVenmoCheckWorker",
      cron: every_hour,
    },
    {
      name: "RefreshNestMessage",
      class: "RefreshNestMessageWorker",
      cron: thursdays_at_noon,
    },
    # {
    #   name:  "Charge Car",
    #   class: "ChargeCarWorker",
    #   cron:  monthly_15th_at_2pm
    # },
    # {
    #   name:  "Charge Brothers",
    #   class: "ChargeBrothersWorker",
    #   cron:  monthly_5th_at_11am
    # }
  ]
end

Rails.application.reloader.to_prepare do
  Sidekiq::Cron::Job.load_from_array!(cron_jobs)
end
