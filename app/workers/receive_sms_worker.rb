# Inbound SMS forwarded from the phone (e.g. an iOS Shortcut POSTing to
# /webhooks/sms). Mirrors ReceiveEmailWorker: fire the generic Jil :sms trigger
# first (additive — lets future user automations claim it), then a hardcoded
# carrier gate routes UPS package updates to the parser; anything else goes to
# Slack so nothing is silently swallowed.
class ReceiveSmsWorker
  include Sidekiq::Worker

  def perform(user_id, text)
    user = ::User.find_by(id: user_id) || ::User.me
    text = text.to_s

    tasks = ::Jil.trigger(user, :sms, { text: text })
    return if tasks.any?(&:stop_propagation?)

    if ::Shipments::SmsRouter.match?(text)
      ::UpsSmsParser.parse(text, user: user)
    else
      notify_slack(text)
    end
  end

  def notify_slack(text)
    ::SlackNotifier.notify(
      ">>> #{text.truncate(500)}",
      channel: "#portfolio", username: "SMS-Bot", icon_emoji: ":speech_balloon:",
    )
  end
end
