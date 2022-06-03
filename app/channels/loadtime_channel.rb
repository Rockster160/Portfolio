class LoadtimeChannel < ApplicationCable::Channel
  def subscribed
    stream_from "loadtime_channel"
    # LoadtimeBroadcast.call
  end

  def receive(_)
    LoadtimeBroadcast.call
  rescue JSON::ParserError
    # No op
  end
end
