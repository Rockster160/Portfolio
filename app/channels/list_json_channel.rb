class ListJsonChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_json_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def message(data)
    puts "\e[33m[LOGIT] | Precheck\e[0m"
    puts "\e[33m[LOGIT] | #{data}\e[0m"
  end
end
