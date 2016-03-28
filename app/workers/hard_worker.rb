class HardWorker
  include Sidekiq::Worker

  def perform
    Rails.logger.warn "\e[31m Hello Rocco! This has been a successful test of the HardWorker scheduled job. \e[0m"
    api = Twilio::REST::Client.new(ENV['PORTFOLIO_TWILIO_ACCOUNT_SID'], ENV['PORTFOLIO_TWILIO_AUTH_TOKEN'])

    begin
      api.account.messages.create(
        body: "Successful test!",
        to: LitterTextReminder.first.turn,
        from: "+18018500855"
      )
    rescue Twilio::REST::RequestError => e
      Rails.logger.warn e
    end
  end

end
