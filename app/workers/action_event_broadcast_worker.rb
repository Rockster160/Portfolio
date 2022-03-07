class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event)
    FitnessBroadcast.call(event)
    RecentEventsBroadcast.call(event)
  end
end
