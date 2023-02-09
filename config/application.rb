require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Portfolio
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.0

    config.secret_key_base = "9066475dd7ba28f4609cdf0e6df34d97216ef815207da74518a2da39f9a9d816a0463f555007fa99eb8f8ac2c875f23d370c2db41387cbfd621e6dca77b19ba4"
    config.active_record.belongs_to_required_by_default = true
    config.action_controller.default_protect_from_forgery = false
    config.assets.quiet = true

    config.action_cable.mount_path = "/cable"

    config.autoload_paths += ["#{config.root}/app/service"]
    config.after_initialize do
      require "#{config.root}/app/service/colorize.rb"
    end

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
