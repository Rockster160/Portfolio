class DeviceBatteryChannel < ApplicationCable::Channel
  def subscribed
    stream_from "device_battery_channel"
  end

  def request(_)
    ActionCable.server.broadcast("device_battery_channel", DataStorage[:device_battery])
  end
end
