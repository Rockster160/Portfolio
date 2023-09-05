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
      name = sched.is_a?(::JarvisTask) ? sched.name : (sched[:name].presence || sched[:command])
      next if name == "Check Car"
      name = name.gsub(/(Remind me (to )?)/i, "•")
      name = name.gsub(/(Take me (to )?)/i, "→")
      name = name.gsub(/((Ping|Text|Tell|Message|SMS|Email) me (to )?)/i, "🗣")

      {
        timestamp: timestamp,
        name: name,
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
      words = new_event[:words].presence || new_event[:command]

      similiar_events = events.select { |event|
        # Only similar if names match
        next true if new_event[:uid] == event[:uid]
        next false unless new_event[:name] == event[:name]
        # In the case we gave it a new uid, check if words match
        evt_words = event[:words].presence || event[:command]
        next false if words.present? && words != evt_words

        # If names match, check if times are the same, making it a match
        similar_time?(Time.parse(event[:scheduled_time]), new_event[:scheduled_time])
      }

      found_duplicate = false
      similiar_events.each do |existing_event|
        jids_to_remove << existing_event[:jid] if found_duplicate

        found_diff = !similar_time?(Time.parse(existing_event[:scheduled_time]), new_event[:scheduled_time])
        found_diff ||= new_event.any? do |k, v|
          next if k == :scheduled_time

          existing_event[k].to_s != v.to_s
        end

        if found_diff
          # Remove the old event then run the rest of the block which adds the new event back
          jids_to_remove << existing_event[:jid]
        else
          # Event already exists- Don't need to add it again
          found_duplicate = true
        end
      end

      next if found_duplicate

      jid = ::JarvisWorker.perform_at(
        new_event[:scheduled_time],
        new_event[:user_id],
        words.present? ? words : JSON.parse({ event: new_event }.to_json)
      )

      new_jids.push(jid)
      events_to_add.push(
        jid: jid,
        name: new_event[:name],
        calendar: new_event[:calendar],
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
