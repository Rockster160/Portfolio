class ListHtmlChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_html_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
