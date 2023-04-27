class RecentEventsBroadcast
  def self.call(user_id)
    return unless user_id

    events = ::ActionEvent.where(user_id: user_id).order(timestamp: :desc).limit(30)

    ActionCable.server.broadcast "recent_events_channel", { recent_events: events.serialize }
  end
end
