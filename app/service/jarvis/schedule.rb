module Jarvis::Schedule
  module_function

  def upcoming
    # Should be per User!
    [*JarvisTask.cron, *Jarvis::Schedule.get_events].map { |sched|
      timestamp = (
        if sched.is_a?(JarvisTask)
          sched.next_trigger_at&.in_time_zone(User.timezone)
        else
          Jarvis::Times.safe_date_parse(sched[:scheduled_time])
        end
      )
      next if timestamp.blank?
      {
        timestamp: timestamp,
        name: sched.is_a?(JarvisTask) ? sched.name : sched[:command],
        recurring: sched.is_a?(JarvisTask) && sched.input
      }
    }.compact.sort_by { |sched| sched[:timestamp] }
  end

  def output_upcoming
    upcoming.each { |a|
      timestamp = a[:timestamp].strftime("%a, %_b %_d %_l:%M%P")
      puts "\e[33m#{timestamp}\e[0m: \e[36m#{a[:name]}\e[0m"
    }; nil
  end

  def get_events
    # Should be per User!
    DataStorage[:scheduled_events] || []
  end

  def schedule(*new_events)
    jids = []
    events = get_events
    new_events.each do |new_event|
      new_event[:uid] = new_event[:uid].presence || SecureRandom.hex
      next if already_scheduled?(new_event[:uid])

      jid = JarvisWorker.perform_at(new_event[:scheduled_time], new_event[:user_id], new_event[:words])

      jids.push(jid)
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
    ::BroadcastUpcomingWorker.perform_async
    jids
  end

  def already_scheduled?(uid)
    DataStorage[:scheduled_events]&.any? { |event| event[:uid] == uid }
  end

  def cancel(*jids)
    Sidekiq::ScheduledSet.new.each do |job|
      job.delete if jids.include?(job.jid)
    end

    cleanup
  end

  def cleanup
    jids = Sidekiq::ScheduledSet.new.map(&:jid)

    events = get_events.select { |evt| evt[:jid].in?(jids) }

    DataStorage[:scheduled_events] = events
    ::BroadcastUpcomingWorker.perform_async
  end
end
