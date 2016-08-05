class LitterReminderWorker
  include Sidekiq::Worker

  def perform
    return true if LitterTextReminder.first.updated_at > 12.hours.ago
    SmsWorker.perform_async(LitterTextReminder.first.turn, "It's your turn to do the litter box! Respond with 'Done!' when you have completed the task.")
  end

end
