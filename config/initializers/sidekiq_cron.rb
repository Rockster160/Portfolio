# Up to date with Local Time

# ::Sidekiq::Cron::Job.destroy_all!
# ::Sidekiq::Cron::Job.all/count
if Rails.env.production?
  ::Sidekiq::Cron::Job.create(name: 'LitterReminder', cron: '0 21 * * *', class: 'LitterReminderWorker')
  ::Sidekiq::Cron::Job.create(name: 'ChargeBrothersWorker', cron: '0 11 5 * *', class: 'ChargeBrothersWorker')
end
