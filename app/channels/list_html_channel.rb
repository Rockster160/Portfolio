class ListHtmlChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_html_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def receive(data)
    # Todo - use strong params and validate id and user
    data = data.deep_symbolize_keys!
    item = ListItem.with_deleted.find(data[:list_item].delete(:id))
    item.update(data[:list_item])
  end
end
