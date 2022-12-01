class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil)
    event = event_id.present? ? ActionEvent.find_by(id: event_id) : nil

    # if event.present?
    #   trigger(
    #     trigger: :action_event,
    #     name: event.event_name,
    #     notes: event.notes,
    #     timestamp: event.timestamp,
    #   )
    # end
    FitnessBroadcast.call(event)
    RecentEventsBroadcast.call
  end
end
