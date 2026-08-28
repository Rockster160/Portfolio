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
    was_deleted = item.deleted?
    item.update(data[:list_item])

    item.notify_jil(transition(was_deleted, item))
  end

  private

  # Ticking a box on the list page is a socket message whenever the page is
  # connected - the HTTP `update`/`destroy` routes are only the offline
  # fallback - so the commonest way an item leaves a list fired no `:item`
  # trigger at all. Same transition rule as ListItemsController#transition:
  # name what happened to the RECORD, not what the message carried.
  def transition(was_deleted, item)
    return :changed if was_deleted == item.deleted?

    item.deleted? ? :removed : :added
  end
end
