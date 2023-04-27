class JarvisWorker
  include Sidekiq::Worker

  def perform(user_id, msg)
    parsed = SafeJsonSerializer.load(msg)

    puts "\e[35m[LOGIT] | JarvisWorker(#{user_id})parsed:[#{parsed.class}]#{parsed}\e[0m"
    case parsed
    when String then ::Jarvis.command(User.find(user_id), parsed)
    when BetterJson, Hash
      event_data = parsed[:event]
      if event_data[:user_id].present? && event_data[:type].present?
        ::Jarvis.trigger(
          event_data[:type],
          { input_vars: { "Event Data": event_data.except(:type, :user_id) } },
          scope: { user_id: event_data[:user_id] }
        )
      end
    else
      puts "\e[35m[LOGIT] | What is it? parsed:[#{parsed.class}]#{parsed}\e[0m"
    end

    ::Jarvis::Schedule.cleanup
  end
end
