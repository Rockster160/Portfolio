# Up to date with Local Time
every_minute = "* * * * *"
daily_9pm = "0 21 * * *"
monthly_5th_at_11am = "0 17 5 * *"

cron_jobs = [
  {
    name: "Reschedule Items",
    class: "RescheduleItemsWorker",
    cron: every_minute
  }
]

if Rails.env.production?
  cron_jobs += [
    {
      name:  "Reminder Messages",
      class: "LitterReminderWorker",
      cron:  daily_9pm
    },
    {
      name:  "Charge Brothers",
      class: "ChargeBrothersWorker",
      cron:  monthly_5th_at_11am
    }
  ]
end

Sidekiq::Cron::Job.load_from_array!(cron_jobs)
