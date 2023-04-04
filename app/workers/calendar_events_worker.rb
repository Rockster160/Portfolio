class CalendarEventsWorker
  include ActionView::Helpers::DateHelper
  include Sidekiq::Worker

  FOLLOWUP_OFFSET = 1.hour
  PRE_OFFSET = 10.minutes

  def perform
    @user_id = 1
    coming_events = LocalDataCalendarParser.call.values.flatten # JarvisCache for @user_id
    sorted_events = coming_events.sort_by { |evt| evt[:start_time] || DateTime.new }
    schedulable_events = gather_events(sorted_events)

    events_to_add = schedulable_events.select { |event| event[:scheduled_time] > 1.minute.from_now }
    event_uids = events_to_add.map { |event| event[:uid] }

    scheduled_events = Jarvis::Schedule.get_events # Only for @user_id
    listing_uids = scheduled_events.map { |evt| evt[:uid] }

    jids_to_remove = scheduled_events.filter_map { |listing|
      !event_uids.include?(listing[:uid]) && listing[:jid]
    }

    Jarvis::Schedule.cancel(*jids_to_remove)
    Jarvis::Schedule.schedule(*events_to_add)
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
    return false unless event[:location].present?

    !online_meeting?(event[:location])
  end

  def gather_events(events)
    now = Time.current.in_time_zone("Mountain Time (US & Canada)")
    events.each_with_object([]) do |(event, idx), new_events|
      # Skip all-day events
      next if event[:start_time].blank? || event[:end_time].blank?

      # If notes starts with Jarvis, send to Jarvis as a message
      if event[:notes]&.match?(/^jarvis:? */i)
        new_events.push(
          name: event[:name],
          uid: event[:uid],
          type: :message,
          words: event[:notes].gsub(/^jarvis:? */i, ""),
          user_id: @user_id,
          scheduled_time: event[:start_time],
        )
      end

      # If travelable - add TT and nav there and back
      if travelable_event?(event)
        traveltime = address_book.traveltime_seconds(event[:location])
        # Show time to leave
        new_events.push(
          name: "Leave now - TT:#{distance_of_time_in_words(traveltime)}",
          uid: event[:uid] + "-tt",
          type: :message,
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
        # Start car + navigate home 10 minutes prior to end-time
        new_events.push(
          uid: event[:uid] + "-home",
          type: :travel,
          words: "Take me home",
          user_id: @user_id,
          scheduled_time: event[:end_time] - PRE_OFFSET,
        )
      else
        # Potential future: Trigger a JarvisTask for every calendar event when it starts
        # new_events.push(
        #   name: event[:name],
        #   uid: event[:uid],
        #   type: :calendar, # TODO: Need a customer JarvisTask for this
        #   # words: event[:notes],
        #   user_id: @user_id,
        #   scheduled_time: event[:start_time],
        # )
      end
    end
  end
end
