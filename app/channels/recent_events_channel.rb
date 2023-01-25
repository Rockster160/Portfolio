class RecentEventsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "recent_events_channel"
  end

  def receive(data)
    data = data.deep_symbolize_keys!

    event = current_user.action_events.create!(
      data.slice(:event_name, :notes, :timestamp)
    )
    ActionEventBroadcastWorker.perform_async(event.id)
  end
end
