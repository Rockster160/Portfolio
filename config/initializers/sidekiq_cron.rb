# Up to date with Local Time
every_5_minutes = "0/15 * * * *"
daily_9pm = "0 21 * * *"
monthly_5th_at_11am = "0 11 5 * *"

cron_jobs = []

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
