class RecentEventsBroadcast
  def self.call
    events = ::ActionEvent.order(timestamp: :desc).limit(30)

    ActionCable.server.broadcast "recent_events_channel", { recent_events: events.serialize }
  end
end
