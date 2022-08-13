class ListHtmlChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_html_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def receive(data)
    puts "\e[33m[LOGIT] | #{data.to_s}\e[0m"
  end
end
