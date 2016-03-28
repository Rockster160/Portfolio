class LitterReminderWorker
  include Sidekiq::Worker

  def perform
    api = Twilio::REST::Client.new(ENV['PORTFOLIO_TWILIO_ACCOUNT_SID'], ENV['PORTFOLIO_TWILIO_AUTH_TOKEN'])

    begin
      api.account.messages.create(
        body: "It's your turn to do the litter box! Respond with 'Done!' when you have completed the task.",
        to: LitterTextReminder.first.turn,
        from: "+18018500855"
      )
    rescue Twilio::REST::RequestError => e
      Rails.logger.warn e
    end
  end

end
