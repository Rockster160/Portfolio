class BroadcastUpcomingWorker
  include Sidekiq::Worker

  def perform
    return # Deprecated via Jil. Keeping temporarily for reference
    ActionCable.server.broadcast(:upcoming_events_channel, ::Jarvis::Schedule.upcoming)
  end
end
