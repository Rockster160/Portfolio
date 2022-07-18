module Jarvis::Schedule
  module_function

  def get_events
    DataStorage[:scheduled_events] || []
  end

  def schedule(*new_events)
    events = get_events
    new_events.each do |new_event|
      jid = JarvisWorker.perform_at(new_event[:scheduled_time], new_event[:user_id], new_event[:words])

      events.push(
        jid: jid,
        scheduled_time: new_event[:scheduled_time],
        user_id: new_event[:user_id],
        command: new_event[:words],
        type: new_event[:type],
        uid: new_event[:uid],
      )
    end

    DataStorage[:scheduled_events] = events
  end

  def cancel(*jids)
    Sidekiq::Queue.new("default").each do |job|
      job.delete if jids.include?(job.jid)
    end

    cleanup
  end

  def cleanup
    jids = Sidekiq::Queue.new("default").map(&:jid)

    events = get_events.select { |evt| evt[:jid].in?(jids) }

    DataStorage[:scheduled_events] = events
  end
end
