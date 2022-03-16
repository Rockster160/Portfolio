config = {
  host:      Redis.current.client.host,
  port:      Redis.current.client.port,
  password:  Redis.current.client.password,
  db:        Redis.current.client.db,
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
