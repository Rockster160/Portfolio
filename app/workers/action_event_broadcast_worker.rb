class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil)
    event = ActionEvent.find_by(id: event_id)

    FitnessBroadcast.call(event)
    RecentEventsBroadcast.call
  end
end
