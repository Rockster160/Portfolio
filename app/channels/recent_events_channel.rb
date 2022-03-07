class RecentEventsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "recent_events_channel"
  end
end
