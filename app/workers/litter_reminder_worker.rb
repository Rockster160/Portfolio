class LitterReminderWorker
  include Sidekiq::Worker

  def perform
    LitterTextReminder.all.each do |rem|
      return true if rem.updated_at > 12.hours.ago
      SmsWorker.perform_async(rem.turn, rem.message)
    end
  end

end
