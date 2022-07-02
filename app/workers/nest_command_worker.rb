class NestCommandWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(name, temp)
    if Rails.env.development?
      return ActionCable.server.broadcast "nest_channel", stubbed_data
    end
    ActionCable.server.broadcast("nest_channel", { loading: true })
    device_name = "Upstairs" if name.to_s.match?(/(up|rooms)/i)
    device_name ||= "Entryway"
    device_data = DataStorage[:devices]
    device = GoogleNestDevice.new(nil, device_data)

    if temp.to_i.to_s == temp.to_s
      device.temp = temp.to_i
      ActionCable.server.broadcast "nest_channel", device.subscription.devices
    else
      ActionCable.server.broadcast "nest_channel", [device.reload]
    end
  rescue StandardError => e
    ActionCable.server.broadcast("nest_channel", { failed: true })
    backtrace = e.backtrace&.map { |l| l.include?("app")&.gsub("`", "'") }.compact.join("\n")
    SlackNotifier.notify("Failed to set Nest: #{e.inspect}\n#{backtrace}")
  end
end
