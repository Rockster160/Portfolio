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

  # Only run within ScheduledEventsWorker
  def schedule(*new_events)
    return if new_events.none?

    new_jids = []
    events = get_events
    jids_to_remove = []
    events_to_add = []

    new_events.each do |new_event|
      new_event[:uid] = new_event[:uid].presence || SecureRandom.hex
      words = new_event[:words] || new_event[:command]

      existing_event = events.find { |event| new_event[:uid] == event[:uid] }
      existing_event ||= events.find { |event|
        next false if (event[:words].presence || event[:command]).blank?
        # Duplicate if words and time match
        next false unless words == (event[:words] || event[:command])

        similar_time?(Time.parse(event[:scheduled_time]), new_event[:scheduled_time])
      }

      if existing_event.present?
        found_diff = !similar_time?(Time.parse(existing_event[:scheduled_time]), new_event[:scheduled_time])
        found_diff ||= new_event.any? do |k, v|
          next if k == :scheduled_time

          existing_event[k].to_s != v.to_s
        end

        if found_diff
          # Remove the old event then run the rest of the block which adds the new event back
          jids_to_remove << existing_event[:jid]
        else
          next # Event already exists- Don't run the rest of the block
        end
      end

      words = new_event[:words] || new_event[:command]
      # jid = ::JarvisWorker.perform_at(new_event[:scheduled_time], new_event[:user_id], words)
      jid = ::JarvisWorker.perform_at(new_event[:scheduled_time], new_event[:user_id], JSON.parse({
        event: new_event
      }.to_json))

      new_jids.push(jid)
      events_to_add.push(
        jid: jid,
        name: new_event[:name],
        scheduled_time: new_event[:scheduled_time],
        user_id: new_event[:user_id],
        command: words,
        type: new_event[:type],
        uid: new_event[:uid],
      )
    end

    ::ScheduledEventsWorker.perform_async(JSON.parse({
      add: events_to_add,
      remove: jids_to_remove
    }.to_json))
    new_jids
  end

  # Only run within ScheduledEventsWorker
  def cancel(*jids)
    return if jids.none?

    ::ScheduledEventsWorker.perform_async(JSON.parse({
      remove: jids
    }.to_json))
  end

  def cleanup
    ::ScheduledEventsWorker.perform_async
  end
end
