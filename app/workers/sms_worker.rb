class SmsWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform(to, msg, media=nil)
    raise "Should not text in tests!" if Rails.env.test?
    return puts("\e[33m[LOGIT] | #{to}:#{msg}\e[0m") if Rails.env.development?

    api = Twilio::REST::Client.new(
      ENV.fetch("PORTFOLIO_TWILIO_ACCOUNT_SID", nil),
      ENV.fetch("PORTFOLIO_TWILIO_AUTH_TOKEN", nil),
    )

    begin
      api.messages.create(**{
        body:      msg,
        to:        to,
        media_url: Array.wrap(media).presence,
        from:      "+18018500855",
      }.compact)
    rescue Twilio::REST::RestError => e
      error_message = "Text Message failed!\nTo: #{to}\nMessage: #{msg}\n\nReason: #{e.message}"
      SmsWorker.perform_async("3852599640", error_message)
      Rails.logger.warn e
    end
  end
end
