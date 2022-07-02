class NestCommandWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(settings)
    ActionCable.server.broadcast("nest_channel", loading: true)
    get_devices if DataStorage[:nest_devices].blank?

    settings = settings.to_s.squish.downcase

    device_name = "Upstairs" if settings.match?(/(up|rooms)/i)
    device_name ||= "Entryway"

    device_data = (DataStorage[:nest_devices] || {})[device_name.to_sym]

    device = GoogleNestDevice.new(nil, device_data)

    device.mode = :heat if settings.match?(/\b(heat)\b/i)
    device.mode = :cool if settings.match?(/\b(cool)\b/i)
    device.temp = settings[/\b\d+\b/].to_i if settings.match?(/\b\d+\b/)

    get_devices
  rescue StandardError => e
    ActionCable.server.broadcast("nest_channel", failed: true)
    backtrace = e.backtrace&.map {|l|l.include?('app') ? l.gsub("`", "'") : nil}.compact.join("\n")
    SlackNotifier.notify("Failed to set Nest: #{e.inspect}\n#{backtrace}")
  end

  def handle_action(device, action)
    if action.to_i.to_s == action.to_s
      device.temp = action.to_i
    elsif action.to_s.downcase.squish.to_sym.in?([:cool, :heat])
      device.mode = action
    end
  end

  def get_devices
    subscription ||= GoogleNestControl.new
    ActionCable.server.broadcast "nest_channel", devices: subscription.devices.map(&:to_json)
  end
end
