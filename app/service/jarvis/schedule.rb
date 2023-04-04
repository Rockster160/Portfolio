module Jarvis::Schedule
  module_function

  def upcoming
    # Should be per User!
    [*::JarvisTask.enabled.cron, *::Jarvis::Schedule.get_events].map { |sched|
      timestamp = (
        if sched.is_a?(::JarvisTask)
          sched.next_trigger_at&.in_time_zone(::User.timezone)
        else
          ::Jarvis::Times.safe_date_parse(sched[:scheduled_time])
        end
      )
      next if timestamp.blank?
      {
        timestamp: timestamp,
        name: sched.is_a?(::JarvisTask) ? sched.name : (sched[:name].presence || sched[:command]),
        recurring: sched.is_a?(::JarvisTask) && sched.input
      }
    }.compact.sort_by { |sched| sched[:timestamp] }
  end

  def output_upcoming
    upcoming.each { |a|
      timestamp = a[:timestamp].strftime("%a, %_b %_d %_l:%M%P")
      puts "\e[33m#{timestamp}\e[0m: \e[36m#{a[:name]}\e[0m"
    }; nil
  end

  def get_events(user=nil)
    # Should be per User!
    ::DataStorage[:scheduled_events] || []
  end

  def similar_time?(time1, time2, coverage=1.minute)
    time1.then { |t| ((t-coverage)..(t+coverage)) }.cover?(time2)
  end

  def schedule(*new_events)
    jids_to_add = []
    events = get_events
    jids_to_remove = []

    new_events.each do |new_event|
      new_event[:uid] = new_event[:uid].presence || SecureRandom.hex

      existing_event = events.find { |event| event[:uid] == new_event[:uid] }
      if existing_event.present?
        found_diff = !similar_time?(Time.parse(existing_event[:scheduled_time]), new_event[:scheduled_time])
        new_event.each do |k, v|
          next if k == :scheduled_time

          found_diff ||= existing_event[k].to_s != v.to_s
        end

        if found_diff
          jids_to_remove << existing_event[:jid]
        else
          next # Don't run the rest of the block- the event already exists
        end
      end

      words = new_event[:words] || new_event[:command]
      jid = ::JarvisWorker.perform_at(new_event[:scheduled_time], new_event[:user_id], words)

      jids_to_add.push(jid)
      events.push(
        jid: jid,
        name: new_event[:name],
        scheduled_time: new_event[:scheduled_time],
        user_id: new_event[:user_id],
        command: words,
        type: new_event[:type],
        uid: new_event[:uid],
      )
    end

    ::DataStorage[:scheduled_events] = events
    cancel(*jids_to_remove) # Triggers cleanup, which triggers broadcast
    jids_to_add
  end

  def cancel(*jids)
    ::Sidekiq::ScheduledSet.new.each do |job|
      job.delete if jids.include?(job.jid)
    end

    cleanup
  end

  def cleanup
    jids = ::Sidekiq::ScheduledSet.new.filter_map { |j| j.klass == "JarvisWorker" && j.jid }

    events = get_events.select { |evt| evt[:jid].in?(jids) }

    ::DataStorage[:scheduled_events] = events
    ::BroadcastUpcomingWorker.perform_async
  end
end
