class BroadcastUpcomingWorker
  include Sidekiq::Worker

  def perform
    ActionCable.server.broadcast("upcoming_events_channel", ::Jarvis::Schedule.upcoming)
  end
end
