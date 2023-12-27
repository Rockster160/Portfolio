class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil, trigger=true)
    event = ::ActionEvent.find_by(id: event_id)

    if event.present? && trigger
      ::UpdateActionStreak.perform_async(event_id)
      ::Jarvis.trigger(
        :action_event,
        {
          id: event.id,
          name: event.event_name,
          notes: event.notes,
          timestamp: event.timestamp,
        },
        scope: { user_id: event.user_id }
      )
    end

    return unless event.user&.me?

    ::FitnessBroadcast.call(event)
    ::RecentEventsBroadcast.call(event.user_id)
  end
end
