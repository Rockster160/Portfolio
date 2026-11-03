Sidekiq.strict_args!(false)

# if Rails.env.development? && !(ENV["RAILS_CONSOLE"] == "true")
#   require 'sidekiq/testing'
#   Sidekiq::Testing.inline!
# end

config_opts = {
  url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/1"),
}

Sidekiq.configure_server { |config|
  config.redis = config_opts

  config.client_middleware { |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  }

  config.server_middleware { |chain|
    chain.add SidekiqUniqueJobs::Middleware::Server
  }

  SidekiqUniqueJobs::Server.configure(config)

  # A job that raises is retried and logged by Sidekiq and seen by nobody, so it
  # goes into the error log too, alongside its retries.
  config.error_handlers << ->(exception, context) { SidekiqErrors.report(exception, context) }
}
Sidekiq.configure_client { |config|
  config.redis = config_opts

  config.client_middleware { |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  }
}
