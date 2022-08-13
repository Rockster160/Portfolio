class ListJsonChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_json_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
