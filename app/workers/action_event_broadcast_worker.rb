class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil)
    event = event_id.present? ? ActionEvent.find_by(id: event_id) : nil

    if event.present?
      ::Jarvis.trigger(
        :action_event,
        {
          name: event.event_name,
          notes: event.notes,
          timestamp: event.timestamp,
        },
        scope: { user_id: event.user_id }
      )
      FitnessBroadcast.call(event)
    end
    RecentEventsBroadcast.call
  end
end
