# Runs every minute (sidekiq-cron) and fires the scheduled morning "Today"
# briefing for any Buddy user who's due — see Buddy::TodayScheduler.
class BuddyTodayWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  def perform
    Buddy::TodayScheduler.run!
  end
end
