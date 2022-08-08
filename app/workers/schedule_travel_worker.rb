class ScheduleTravelWorker
  include Sidekiq::Worker

  PRE_OFFSET = 5.minutes
  POST_OFFSET = 20.minutes

  def perform
    return if Rails.env.development?

    calendar_data = LocalDataCalendarParser.call
    _date, events = calendar_data.first # First should always be "today"
    events = events.sort_by { |evt| evt[:start_time] }
    event_listings = Jarvis::Schedule.get_events
    listing_uids = event_listings.map { |evt| evt[:uid] }
    travel_events = schedulable_travel_events(events)
    travel_uids = travel_events.map { |evt| evt[:uid] }
    other_events = other_events(events)
    other_uids = other_events.map { |evt| evt[:uid] }

    events_to_add = []
    jids_to_remove = []
    event_types = [:travel, :pt]

    event_listings.each do |event_listing|
      event_type = event_listing[:type].to_s.downcase.to_sym
      if event_type == :travel
        # Remove/cancel if no longer present in calendar
        if travel_uids.include?(event_listing[:uid])
          rescheduled_uids = events.map { |evt|
            next unless event_listing[:uid].starts_with?(evt[:uid])
            next if (evt[:start_time] - PRE_OFFSET).to_s == event_listing[:scheduled_time].to_s

            evt[:uid]
          }.compact

          listing_uids.delete_if { |uid| rescheduled_uids.any? { |ruid| uid&.starts_with?(ruid) } }
          next if rescheduled_uids.none?
        end
      elsif event_type == :pt
        if other_uids.include?(event_listing[:uid])
          rescheduled_uids = events.map { |evt|
            next unless event_listing[:uid].starts_with?(evt[:uid])
            next if evt[:start_time].to_s == event_listing[:scheduled_time].to_s

            evt[:uid]
          }.compact

          listing_uids.delete_if { |uid| rescheduled_uids.any? { |ruid| uid&.starts_with?(ruid) } }
          next if rescheduled_uids.none?
        end
      end

      jids_to_remove.push(event_listing[:jid]) if event_type.in?(event_types)
    end

    travel_events.each do |travel_event|
      # Add new event if calendar /  Do NOT add duplicates
      events_to_add.push(travel_event) unless listing_uids.include?(travel_event[:uid])
    end

    other_events.each do |other_event|
      # Add new event if calendar /  Do NOT add duplicates
      events_to_add.push(other_event) unless listing_uids.include?(other_event[:uid])
    end

    Jarvis::Schedule.cancel(*jids_to_remove)
    Jarvis::Schedule.schedule(*events_to_add)
  end

  def address_book
    @address_book ||= User.find(1).address_book
  end

  def other_events(events)
    now = Time.current.in_time_zone("Mountain Time (US & Canada)")
    events.each_with_object([]) do |(event, idx), new_events|
      next if event[:start_time] - 1.minute < now # Extra minute for padding

      if event[:name].to_s.downcase.to_sym == :pt
        new_events.push(
          name: event[:name],
          uid: event[:uid],
          type: :pt,
          words: "Remind me to start workout",
          user_id: 1,
          scheduled_time: event[:start_time],
        )
      end
    end
  end

  def schedulable_travel_events(events)
    return # Temp until Tesla is back to life
    now = Time.current.in_time_zone("Mountain Time (US & Canada)")
    events.each_with_object([]) do |(event, idx), new_events|
      next unless event[:name].to_s.downcase.to_sym == :travel
      next if event[:start_time] - PRE_OFFSET - 1.minute < now # Extra minute for padding

      new_events.push(
        name: event[:name],
        uid: event[:uid],
        type: :travel,
        words: "Start car",
        user_id: 1,
        scheduled_time: event[:start_time] - PRE_OFFSET,
      )

      followup_events = events.select do |followup_event|
        next if followup_event[:name].to_s.downcase.to_sym == :travel
        travel_range = (event[:start_time] - PRE_OFFSET)..(event[:end_time] + POST_OFFSET)

        followup_event if travel_range.cover?(followup_event[:start_time])
      end

      traveling_to = followup_events.map { |evt|
        break evt if evt[:location].present? && !evt[:location].include?("Webinar")

        contact = address_book.contact_by_name(evt[:name])
        next unless contact

        break evt.merge(location: contact[:address])
      }.compact

      if traveling_to.present?
        new_events.push(
          uid: traveling_to[:uid],
          type: :travel,
          words: "Take me to #{traveling_to[:location]}",
          user_id: 1,
          scheduled_time: event[:start_time] - PRE_OFFSET,
        )
      elsif followup_events.none?
        new_events.push(
          uid: event[:uid] + "-1", # Adding an extra char so the uids are different
          type: :travel,
          words: "Take me home",
          user_id: 1,
          scheduled_time: event[:start_time] - PRE_OFFSET,
        )
      end
    end
  end
end
