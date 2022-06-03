class LoadtimeChannel < ApplicationCable::Channel
  def subscribed
    stream_from "loadtime_channel"
  end

  def request(_)
    LoadtimeBroadcast.call
  rescue JSON::ParserError
    # No op
  end
end
