class ActionEventBroadcastWorker
  include Sidekiq::Worker

  def perform(event_id=nil, trigger=true)
    event = ::ActionEvent.find_by(id: event_id)

    if event.present? && trigger
      ::UpdateActionStreak.perform_async(event_id)
    end

    return unless event&.user&.me?

    ::FitnessBroadcast.broadcast
    ::RecentEventsBroadcast.call
  end
end
