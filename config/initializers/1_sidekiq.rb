Sidekiq.strict_args! if Rails.env.test?

if Rails.env.development?
  require 'sidekiq/testing'
  Sidekiq::Testing.inline!
end

config_opts = { url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0") }

Sidekiq.configure_server { |config|
  config.redis = config_opts

  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end

  config.server_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Server
  end

  SidekiqUniqueJobs::Server.configure(config)
}
Sidekiq.configure_client { |config|
  config.redis = config_opts

  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end
}
