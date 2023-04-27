class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil, trigger=true)
    event = ::ActionEvent.find_by(id: event_id)

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
    ::RecentEventsBroadcast.call(event.user_id) if event.present?
  end
end
