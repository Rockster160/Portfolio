class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil, trigger=true)
    event = ::ActionEvent.find_by(id: event_id)
    ::FitnessBroadcast.call(event)

    return unless event.present?

    if event.present? && trigger
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

    ::UpdateActionStreak.perform_async(event_id)
    return unless event.user&.me?

    ::RecentEventsBroadcast.call(event.user_id)
  end
end
