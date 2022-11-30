Sidekiq.strict_args! if Rails.env.test?

if Rails.env.development?
  require 'sidekiq/testing'
  Sidekiq::Testing.inline!
end

config = { url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0") }

Sidekiq.configure_server { |c| c.redis = config }
Sidekiq.configure_client { |c| c.redis = config }
