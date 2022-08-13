class ListJsonChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_json_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def message(data)
    data = data.deep_symbolize_keys!
    list = List.find(params[:channel_id])

    if data[:get]
      list.broadcast!
    end

    list.update(data.slice(:add, :remove))
  end
end
