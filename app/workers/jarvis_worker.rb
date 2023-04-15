class JarvisWorker
  include Sidekiq::Worker

  def perform(user_id, msg)
    parsed = SafeJsonSerializer.load(msg)

    case parsed
    when String then ::Jarvis.command(User.find(user_id), parsed)
    when Hash
      event_data = parsed[:event]
      if event_data[:user_id].present? && event_data[:type].present?
        ::Jarvis.trigger(
          event[:type],
          { input_vars: { "Event Data": event.except(:type, :user_id) } }.to_json
          scope: { user_id: event[:user_id] }
        )
      end
    end

    ::Jarvis::Schedule.cleanup
  end
end
