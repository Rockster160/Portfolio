class RecentEventsBroadcast
  def self.call
    events = User.me.action_events.order(timestamp: :desc).limit(30)
    ActionCable.server.broadcast(:recent_events_channel, { recent_events: events.serialize })
  end
end
