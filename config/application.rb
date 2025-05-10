require_relative "boot"

require "rails/all"

require_relative "../lib/middleware/catch_mime_negotiation_middleware"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Portfolio
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.0

    config.secret_key_base = ENV["PORTFOLIO_SECRET"]
    config.active_record.belongs_to_required_by_default = true
    config.action_controller.default_protect_from_forgery = true
    config.assets.quiet = true

    config.action_cable.mount_path = "/cable"

    config.autoload_paths += ["#{config.root}/app/service"]

    config.after_initialize do
      require "#{config.root}/app/service/colorize.rb"
      require "#{config.root}/app/service/better_json.rb"
    end

    config.middleware.use ::CatchMimeNegotiationMiddleware
  end
end
