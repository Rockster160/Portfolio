class LocalDataChannel < ApplicationCable::Channel
  def subscribed
    stream_from "local_data_channel"
  end

  def request(_)
    LocalDataBroadcast.call
  rescue JSON::ParserError
    # No op
  end
end
