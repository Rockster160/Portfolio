class PingChannel < ApplicationCable::Channel
  def subscribed
    stream_from "ping_channel"
  end

  def receive(data)
    ActionCable.server.broadcast("ping_channel", { msg: "Thanks! I got your packet.", data: data })
  end
end
