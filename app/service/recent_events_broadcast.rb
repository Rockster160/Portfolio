class RecentEventsBroadcast
  def self.call(event)
    events = ::ActionEvent.order(timestamp: :desc).first(10)

    ActionCable.server.broadcast "recent_events_channel", recent_events: events.pluck(:event_name)
  end
end
