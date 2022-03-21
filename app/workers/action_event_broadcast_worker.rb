class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil)
    event = event_id.present? ? ActionEvent.find_by(id: event_id) : nil

    FitnessBroadcast.call(event)
    RecentEventsBroadcast.call
  end
end
