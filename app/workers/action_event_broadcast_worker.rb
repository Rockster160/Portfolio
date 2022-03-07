class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id)
    event = ActionEvent.find(event_id)

    FitnessBroadcast.call(event)
    RecentEventsBroadcast.call
  end
end
