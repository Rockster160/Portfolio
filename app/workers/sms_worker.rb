class SmsWorker
  include Sidekiq::Worker

  def perform(to, msg)
    api = Twilio::REST::Client.new(ENV['PORTFOLIO_TWILIO_ACCOUNT_SID'], ENV['PORTFOLIO_TWILIO_AUTH_TOKEN'])

    begin
      api.account.messages.create(
        body: msg,
        to: to,
        from: "+18018500855"
      )
    rescue Twilio::REST::RequestError => e
      Rails.logger.warn e
    end
  end

end
