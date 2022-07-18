class ScheduleTravelWorker
  include Sidekiq::Worker

  def perform
    # Should be idempotent, rerun every change of calendar?
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
      next unless event_listing[:name].downcase.to_sym == :travel
      # Remove/cancel if no longer present in calendar
      jids_to_remove.push(event_listing[:jid]) unless uids.include?(event_listing[:uid])

      # Reschedule items if the timestamps don't match
      timestamp = Time.parse(event_listing[:scheduled_time])
      next if travel_events.any? { |travel_event| times_near?(travel_event[:start_time], timestamp) }

      listing_uids.delete_if { |uid| uid == travel_event[:uid] }
    end

    travel_events.each do |travel_event|
      # Add new event if calendar /  Do NOT add duplicates
      events_to_add.push(travel_event[:uid]) unless listing_uids.include?(travel_event[:uid])
    end
  end

  def times_near?(time1, time2)
    (time1 - time2).abs < 1.minute
  end

  def schedulable_events(events)
    events.each_with_object([]) do |(event, idx), new_events|
      next unless event[:name].downcase.to_sym == :travel

      new_events.push(
        uid: event[:uid],
        type: :travel,
        words: "Start car",
        user_id: 1,
        scheduled_time: event[:start_time] - 5.minutes,
      )

      followup_events = events.filter_map do |followup_event|
        travel_range = (event[:start_time] - 5.minutes)..(event[:end_time] + 20.minutes)

        travel_range.cover?(followup_event[:start_time])
      end

      traveling_to = followup_events.filter_map { |evt|
        next if evt[:location]&.include?("Webinar")

        evt[:location]
      }.compact.first

      if traveling_to.present?
        new_events.push(
          uid: traveling_to[:uid],
          type: :travel,
          words: "Take me to #{traveling_to}",
          user_id: 1,
          scheduled_time: event[:start_time] - 5.minutes,
        )
      elsif followup_events.none?
        new_events.push(
          uid: event[:uid],
          type: :travel,
          words: "Take me home",
          user_id: 1,
          scheduled_time: event[:start_time] - 5.minutes,
        )
      end
    end
  end
end
