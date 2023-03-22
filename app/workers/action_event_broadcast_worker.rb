class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil, trigger: true)
    event = event_id.present? ? ::ActionEvent.find_by(id: event_id) : nil

    if event.present? && trigger
      ::Jarvis.trigger(
        :action_event,
        {
          name: event.event_name,
          notes: event.notes,
          timestamp: event.timestamp,
        },
        scope: { user_id: event.user_id }
      )
    end
    ::UpdateActionStreak.perform_async(event_id) if event.present?
    ::FitnessBroadcast.call(event)
    ::RecentEventsBroadcast.call
  end
end
