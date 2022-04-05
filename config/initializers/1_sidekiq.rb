config = {
  url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"),
  namespace: "#{Rails.application.class.parent_name}_#{Rails.env}:sidekiq"
}

if Rails.env.development?
  require 'sidekiq/testing'
  Sidekiq::Testing.inline!
end

Sidekiq.configure_server do |c|
  c.redis = config
  c.error_handlers << Proc.new do |exception, context_hash|
    webhook = "https://hooks.slack.com/services/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"
    ::Slack::Notifier.new(webhook, channel: "#portfolio", username: "Help-Bot").ping("Sidekiq Error: >>> #{exception}: #{context_hash}", attachments: [])
  end
end
Sidekiq.configure_client { |c| c.redis = config }
