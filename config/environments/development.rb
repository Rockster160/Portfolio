require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.cache_classes = false

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :memory_store
    config.public_file_server.headers = {
      "Cache-Control" => "public, max-age=#{2.days.to_i}"
    }
  else
    config.action_controller.perform_caching = false

    config.cache_store = :null_store
  end

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  config.action_mailer.perform_caching = false

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load
  # config.active_record.migration_error = false

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  # ========================================
  config.action_dispatch.default_headers['X-Frame-Options'] = "ALLOWALL"
  config.action_cable.url = "ws://localhost:3141/cable"
  config.web_socket_server_url = "ws://localhost:3141/cable"
  config.action_cable.disable_request_forgery_protection = true

  routes.default_url_options = { protocol: "http://", host: "localhost", port: "3141" }
  config.action_mailer.default_url_options = routes.default_url_options

  config.public_file_server.enabled = true

  # Run ActiveJobs inline- this is mostly a fix for the CommandProposal to work properly
  #   since it uses multiple threads which jams up the single process in development
  config.active_job.queue_adapter = :inline
  # ActiveJob options to allow for custom queues
  config.active_job.queue_name_prefix = Rails.env
  config.active_job.queue_name_delimiter = "."
  config.active_job.default_queue_name = "default"
  config.active_job.custom_queues = {
    critical: 1,       # Custom queue with a priority of 1
    tesla_local: 5     # Custom queue with a priority of 5
  }

  config.hosts = nil
  config.serve_static_assets = false
  config.assets.debug = true
  config.assets.digest = false
end
