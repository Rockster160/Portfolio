require_relative "boot"

require "rails/all"

require_relative "../lib/middleware/catch_malformed_request_middleware"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Portfolio
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.0

    config.global_id.app = "Jarvis"

    config.secret_key_base = ENV.fetch("PORTFOLIO_SECRET", nil)
    config.active_record.belongs_to_required_by_default = true
    config.action_controller.default_protect_from_forgery = true
    config.assets.quiet = true

    config.action_cable.mount_path = "/cable"

    config.autoload_paths += ["#{config.root}/app/service"]

    # Buddy tool files under app/service/buddy/tools/ don't define constants —
    # they only call `Buddy::Tools.register(...)` at load time. Zeitwerk would
    # otherwise raise Zeitwerk::NameError on eager_load looking for e.g.
    # Buddy::Tools::AddAgendaItem. The buddy_tools initializer explicitly
    # `load`s each file after boot.
    Rails.autoloaders.main.ignore("#{config.root}/app/service/buddy/tools")

    config.after_initialize do
      require "#{config.root}/app/service/colorize.rb"
      require "#{config.root}/app/service/better_json.rb"
    end

    config.middleware.use ::CatchMalformedRequestMiddleware
  end
end
