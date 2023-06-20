class CalendarEventsWorker
  include Sidekiq::Worker
  include ActionView::Helpers::DateHelper

  FOLLOWUP_OFFSET = 1.hour
  PRE_OFFSET = 10.minutes

  def perform
    return if Rails.env.development?

    @user_id = 1
    coming_events = ::LocalDataCalendarParser.call.values.flatten # JarvisCache for @user_id
    sorted_events = coming_events.sort_by { |evt| evt[:start_time] || ::DateTime.new }
    schedulable_events = gather_events(sorted_events)

    events_to_add = schedulable_events.select { |event| event[:scheduled_time].to_i > 1.minute.from_now.to_i }
    event_uids = events_to_add.map { |event| event[:uid] }

    scheduled_events = ::Jarvis::Schedule.get_events # Only for @user_id
    listing_uids = scheduled_events.map { |evt| evt[:uid] }

    # Previous events DO have UID - does that come through over here?
    jids_to_remove = scheduled_events.filter_map { |listing|
      # Commands aren't scheduled, so skip them to prevent them being removed
      next if listing[:type] == "command"
      # If an event is about to run, do not remove it
      next if Time.parse(listing[:scheduled_time]).to_i < 1.minute.from_now.to_i
      # listing[:jid] last as the implicit return of the map
      listing[:uid].present? && !event_uids.include?(listing[:uid]) && listing[:jid]
    }

    ::Jarvis::Schedule.cancel(*jids_to_remove)
    ::Jarvis::Schedule.schedule(*events_to_add)
  end

  def address_book
    @address_book ||= User.find(@user_id).address_book
  end

  def online_meeting?(location)
    return true if location.include?("zoom.us")
    return true if location.include?("meet.google")
    return true if location.match?(/webinar/i) # GoToWebinar
  end

  def travelable_event?(event)
    return false # JAPAN - No travel / auto starts
    return false unless event[:location].present?

    !online_meeting?(event[:location])
  end

  def calendar_event?(event)
    return false
  end

  def gather_events(events)
    now = Time.current.in_time_zone("Mountain Time (US & Canada)")
    events.each_with_object([]) do |(event, idx), new_events|
      next if event[:start_time].blank? || event[:end_time].blank? # Skip all-day events

      event[:uid] = "unix:#{event[:start_time].to_i}:#{event[:uid]}"

      # If notes starts with Jarvis, send to Jarvis as a message
      if event[:notes]&.match?(/^jarvis[:,]? */i)
        new_events.push(
          name: event[:name],
          uid: event[:uid] + "-notes",
          type: :message,
          words: event[:notes].gsub(/^jarvis:? */i, ""),
          user_id: @user_id,
          scheduled_time: event[:start_time],
        )
      end

      # Trigger a Calendar event for everything that comes through
      new_events.push(
        name: event[:name],
        uid: event[:uid],
        type: :calendar,
        notes: event[:notes],
        user_id: @user_id,
        scheduled_time: event[:start_time],
      )

      # Add helper to get "current location at time" which looks through scheduled events
      # if between start of event and 1 hour after event
      #   (priority to "during" event - so that back to back events don't grab the previous one
      #   with the extra time)
      #   Set location for time there, otherwise default to home

      # If travelable - add TT and nav there and back
      if travelable_event?(event)
        traveltime = address_book.traveltime_seconds(event[:location], address_book.current_contact&.loc)
        # Show time to leave
        new_events.push(
          name: "TTL: #{distance_of_time_in_words(traveltime)}",
          uid: event[:uid] + "-tt",
          type: :travel,
          words: "Ping me Time to leave! It will take #{distance_of_time_in_words(traveltime)} to travel.",
          user_id: @user_id,
          scheduled_time: event[:start_time] - traveltime - 2.minutes,
        )
        # Start car + navigate 10 minutes prior to time-to-leave
        new_events.push(
          uid: event[:uid] + "-travel",
          type: :travel,
          words: "Take me to #{event[:location].presence || event[:name]}",
          user_id: @user_id,
          scheduled_time: event[:start_time] - traveltime - PRE_OFFSET,
        )
        # TODO: Only nav home if there are no other events
        # Also time estimate should be from "current" location-
        #   guessed based on the last event left us at
        # Start car + navigate home 10 minutes prior to end-time
        new_events.push(
          uid: event[:uid] + "-home",
          type: :travel,
          words: "Take me home",
          user_id: @user_id,
          scheduled_time: event[:end_time] - PRE_OFFSET,
        )
      end
    end
  end
end
