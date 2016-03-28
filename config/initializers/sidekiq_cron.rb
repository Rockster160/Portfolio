# ::Sidekiq::Cron::Job.destroy_all!
# ::Sidekiq::Cron::Job.all/count
::Sidekiq::Cron::Job.create(name: 'LitterReminder', cron: '0 8 * * *', class: 'LitterReminderWorker')
::Sidekiq::Cron::Job.create(name: 'HardWorker', cron: '*/5 * * * *', class: 'HardWorker')
