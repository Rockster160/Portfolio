class UpcomingEventsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "upcoming_events_channel"
  end

  def request
    ::BroadcastUpcomingWorker.perform_async
  end
end
