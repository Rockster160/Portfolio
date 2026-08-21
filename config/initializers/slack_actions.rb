# Slack link controls, registered at boot. See Slack::Actions.
Rails.application.config.to_prepare do
  Slack::Actions.register(
    :buddy_retry,
    label: "🔄 Try Buddy again",
    run:   ->(_params) { Buddy::Outage.retry! },
  )
end
