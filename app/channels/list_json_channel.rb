class ListJsonChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_json_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def receive(data)
    data = data.deep_symbolize_keys!
    list = List.find(params[:channel_id].gsub(/^list_/, ""))

    if data[:get]
      list.broadcast!
    else
      list.update(data.slice(:add, :remove))
    end
  end
end
