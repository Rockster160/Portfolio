class TeslaCommandWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(cmd, params=nil, update_later=true)
    TeslaCommand.command(cmd, params)

    return unless update_later
    sleep 3 unless Rails.env.test? # Give the API a chance to update
    TeslaCommand.command(:reload)
  end
end
