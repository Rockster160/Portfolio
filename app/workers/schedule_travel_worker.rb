class ScheduleTravelWorker
  include Sidekiq::Worker

  def perform
    return if Rails.env.development?

    calendar_data = LocalDataCalendarParser.call
    _date, events = calendar_data.first # First should always be "today"
    events = events.sort_by { |evt| evt[:start_time] }
    event_listings = Jarvis::Schedule.get_events
    listing_uids = event_listings.map { |evt| evt[:uid] }
    travel_events = schedulable_events(events)
    uids = travel_events.map { |evt| evt[:uid] }

    events_to_add = []
    jids_to_remove = []

    event_listings.each do |event_listing|
      next unless event_listing[:name].to_s.downcase.to_sym == :travel
      # Remove/cancel if no longer present in calendar
      jids_to_remove.push(event_listing[:jid]) unless uids.include?(event_listing[:uid])

      # Reschedule items if the timestamps don't match
      timestamp = Time.parse(event_listing[:scheduled_time])
      next if travel_events.any? { |travel_event| times_near?(travel_event[:start_time], timestamp) }

      listing_uids.delete_if { |uid| uid == travel_event[:uid] }
    end

    travel_events.each do |travel_event|
      # Add new event if calendar /  Do NOT add duplicates
      events_to_add.push(travel_event) unless listing_uids.include?(travel_event[:uid])
    end

    Jarvis::Schedule.schedule(*events_to_add)
    Jarvis::Schedule.cancel(*jids_to_remove)
  end

  def times_near?(time1, time2)
    (time1 - time2).abs < 1.minute
  end

  def schedulable_events(events)
    now = Time.current.in_time_zone("Mountain Time (US & Canada)")
    events.each_with_object([]) do |(event, idx), new_events|
      next unless event[:name].to_s.downcase.to_sym == :travel
      next if event[:start_time] - 6.minutes < now # Extra minute for padding

      new_events.push(
        name: event[:name],
        uid: event[:uid],
        type: :travel,
        words: "Start car",
        user_id: 1,
        scheduled_time: event[:start_time] - 5.minutes,
      )

      followup_events = events.select do |followup_event|
        next if followup_event[:name].to_s.downcase.to_sym == :travel
        travel_range = (event[:start_time] - 5.minutes)..(event[:end_time] + 20.minutes)

        followup_event if travel_range.cover?(followup_event[:start_time])
      end

      traveling_to = followup_events.map { |evt|
        break evt if evt[:location].present? && !evt[:location].include?("Webinar")

        contact = AddressBook.contact_by_name(evt[:name])
        next unless contact

        break evt.merge(location: contact[:address])
      }.compact

      if traveling_to.present?
        new_events.push(
          uid: traveling_to[:uid],
          type: :travel,
          words: "Take me to #{traveling_to[:location]}",
          user_id: 1,
          scheduled_time: event[:start_time] - 5.minutes,
        )
      elsif followup_events.none?
        new_events.push(
          uid: event[:uid] + "-1", # Adding an extra char so the uids are different
          type: :travel,
          words: "Take me home",
          user_id: 1,
          scheduled_time: event[:start_time] - 5.minutes,
        )
      end
    end
  end
end
