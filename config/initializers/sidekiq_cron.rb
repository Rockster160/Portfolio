# Server time is -3 hours from Utah Time!!


# ::Sidekiq::Cron::Job.destroy_all!
# ::Sidekiq::Cron::Job.all/count
if Rails.env.production?
  ::Sidekiq::Cron::Job.create(name: 'LitterReminder', cron: '0 23 * * *', class: 'LitterReminderWorker')
  ::Sidekiq::Cron::Job.create(name: 'ChargeBrothersWorker', cron: '0 14 5 * *', class: 'ChargeBrothersWorker')
  # ::Sidekiq::Cron::Job.create(name: 'PokemonWalkerWorker', cron: '*/5 * * * *', class: 'PokemonWalkerWorker')
end
