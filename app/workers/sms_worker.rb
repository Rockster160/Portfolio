class SmsWorker
  include Sidekiq::Worker

  def perform(to, msg)
    return puts("\e[33m[LOGIT] | #{to}:#{msg}\e[0m") if Rails.env.development?

    api = Twilio::REST::Client.new(ENV['PORTFOLIO_TWILIO_ACCOUNT_SID'], ENV['PORTFOLIO_TWILIO_AUTH_TOKEN'])

    begin
      api.account.messages.create(
        body: msg,
        to: to,
        from: "+18018500855"
      )
    rescue Twilio::REST::RequestError => e
      error_message = "Text Message failed!\nTo: #{to}\nMessage: #{msg}\n\nReason: #{e.message}"
      SmsWorker.perform_async("3852599640", error_message)
      Rails.logger.warn e
    end
  end

end
