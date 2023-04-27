class JarvisWorker
  include Sidekiq::Worker

  def perform(user_id, msg)
    # user_id, msg = 1, {"event"=>{"name"=>"Laundry", "uid"=>"unix:1682567100:98D625D1-4BEB-4EAD-9852-C7353A333CA2", "type"=>"calendar", "notes"=>nil, "user_id"=>1, "scheduled_time"=>"2023-04-26T21:45:00.000-06:00"}}
    puts "\e[35m[LOGIT] | #{user_id}, #{msg}\e[0m"
    parsed = SafeJsonSerializer.load(msg)
    case parsed
    when String
      puts "\e[35m[LOGIT] | parsed is a string:[#{parsed.class}]#{parsed}\e[0m"
      ::Jarvis.command(User.find(user_id), parsed)
    when Hash
      puts "\e[35m[LOGIT] | parsed is a hash:[#{parsed.class}]#{parsed}\e[0m"
      event_data = parsed[:event]
      if event_data[:user_id].present? && event_data[:type].present?
        puts "\e[35m[LOGIT] | calling trigger:[#{parsed.class}]#{parsed}\e[0m"
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
