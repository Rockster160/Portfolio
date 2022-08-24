class UptimeChannel < ApplicationCable::Channel
  def subscribed
    stream_from "uptime_channel"
  end
end
