# Inbound SMS forwarded from somewhere other than the phone (POSTing to
# /webhooks/sms). Fires the generic Jil :sms trigger so user automations can
# claim it, then falls through to Slack so nothing is silently swallowed.
#
# Carrier parsing deliberately does NOT live here: anything coming off the
# phone arrives on its own Jil trigger (`ups`), and that task hands the text to
# `Custom.UPSPackage` — see Jil::Methods::Custom.
class ReceiveSmsWorker
  include Sidekiq::Worker

  def perform(user_id, text)
    user = ::User.find_by(id: user_id) || ::User.me
    text = text.to_s

    tasks = ::Jil.trigger(user, :sms, { text: text })
    return if tasks.any?(&:stop_propagation?)

    notify_slack(text)
  end

  def notify_slack(text)
    ::SlackNotifier.notify(
      ">>> #{text.truncate(500)}",
      channel: "#portfolio", username: "SMS-Bot", icon_emoji: ":speech_balloon:",
    )
  end
end
