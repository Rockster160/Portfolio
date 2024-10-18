# Deprecated! Use Monitors + Jil instead
class RecentEventsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "recent_events_channel"
  end

  def receive(data)
    data = data.deep_symbolize_keys!

    event = current_user.action_events.create!(
      data.slice(:name, :notes, :timestamp)
    )
    ::Jil.trigger(event.user_id, :event, event.serialize.merge(action: :added))
    ActionEventBroadcastWorker.perform_async(event.id)
  end
end
