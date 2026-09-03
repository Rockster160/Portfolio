module Buddy
  # Finding something on the calendar by name, outside the window the context
  # already carries.
  #
  # `today_agenda` is today and `upcoming_agenda` is the next eight days, and
  # for a long time that was everything Buddy could see. "When is my next 1-1
  # with Eric?" is not answerable from eight days of calendar, but it LOOKS
  # answerable — there is always something in the window — so it got answered
  # from whatever was nearest. Prod Aug 3: the reply named 11:00 AM Wednesday,
  # which is a real 11:00 AM Wednesday item called "Zoom meet with Bri", and it
  # took three rounds of being told otherwise before it backed down.
  #
  # Same calendars as the briefing (Buddy::Context.agenda_source_map), so a
  # search can never surface something the rest of Buddy can't see.
  module AgendaSearch
    module_function

    DEFAULT_DAYS = 180
    MAX_DAYS     = 1_095
    LIMIT        = 12

    # Which side of now to look at. "When is my NEXT dentist" and "when did I
    # LAST see Eric" are the same lookup pointed opposite ways, and answering
    # one with the other is worse than saying nothing.
    DIRECTIONS = %i[upcoming past any].freeze

    def call(user:, query:, direction: :upcoming, days: DEFAULT_DAYS, limit: LIMIT)
      sources = Buddy::Context.agenda_source_map(user)
      return { items: [], total: 0, sources: {} } if sources.empty?

      scope = AgendaItem.where(agenda_id: sources.keys).where.not(status: :cancelled)
      scope = scope.where("LOWER(name) LIKE ?", "%#{query.to_s.strip.downcase}%") if query.present?
      scope = scope.where(start_at: window(direction, days))

      # Nearest to now first, whichever way we're facing: the answer to "when's
      # my next X" is the soonest one, and to "when did I last X" the most
      # recent. Ordering by date alone gets one of those two backwards.
      order = direction.to_sym == :past ? { start_at: :desc } : { start_at: :asc }
      items = scope.includes(:agenda, :agenda_schedule).order(order).limit(limit).to_a

      phantoms = unmaterialized(user, sources, query, direction, days, limit)
      if phantoms.any?
        items = (items + phantoms).sort_by(&:start_at)
        items = items.reverse if direction.to_sym == :past
        items = items.first(limit)
      end

      { items: items, total: scope.count + phantoms.length, sources: sources }
    end

    # Occurrences of a repeating series that have no row yet.
    #
    # AgendaSchedule::MATERIALIZE_WINDOW is 30 hours, so a weekly series created
    # on Sunday evening has exactly one real row and four rules. Searching
    # AgendaItem alone therefore cannot see a series Buddy itself created a
    # minute earlier - which is what prod 4462-4471 was: five dinners went on,
    # and then two companions over four turns told him the other four weren't
    # there. "The others don't seem to be sitting there under those exact
    # titles." They were on the calendar he was looking at the whole time; the
    # browser expands the rule (Agenda.items_for_range_in) and this didn't.
    #
    # Phantoms are unsaved AgendaItems, exactly as the calendar builds them, so
    # everything downstream reads them like any other row. They carry no `id` -
    # see `row` and ToolContext#resolve_agenda_item, both of which key off the
    # schedule for a series.
    def unmaterialized(user, sources, query, direction, days, limit)
      window = window(direction, days)
      zone   = ActiveSupport::TimeZone[user.timezone] || Time.zone
      from   = window.first.in_time_zone(zone).to_date
      to     = window.last.in_time_zone(zone).to_date

      schedules = AgendaSchedule.where(agenda_id: sources.keys).active_between(from, to)
      schedules = schedules.where("LOWER(name) LIKE ?", "%#{query.to_s.strip.downcase}%") if query.present?
      schedules = schedules.includes(:agenda, :agenda_items).limit(limit).to_a
      return [] if schedules.empty?

      dates = direction.to_sym == :past ? (from..to).to_a.reverse : (from..to).to_a
      schedules.flat_map { |schedule| occurrences_for(schedule, dates, limit) }
    end

    # Up to `limit` occurrences of one rule, skipping the dates that already
    # have a row - those came back from the AgendaItem query and a phantom
    # beside one would be the same evening listed twice.
    def occurrences_for(schedule, dates, limit)
      taken = schedule.agenda_items.reject(&:detached_at).to_set(&:occurrence_date)
      found = []
      dates.each { |date|
        break if found.length >= limit
        next if taken.include?(date) || !schedule.matches?(date)

        found << schedule.build_phantom(date)
      }
      found
    end

    def window(direction, days)
      span = days.to_i.clamp(1, MAX_DAYS).days
      case direction.to_sym
      when :past then (Time.current - span)...Time.current
      when :any  then (Time.current - span)..(Time.current + span)
      else            Time.current..(Time.current + span)
      end
    end

    # One line per hit. The id leads because edit_agenda_item takes it, and the
    # calendar name is on there because a partner's shared item is NOT theirs to
    # treat as a task — same distinction the briefing draws.
    def rows(items, user, sources=nil)
      sources ||= Buddy::Context.agenda_source_map(user)
      items.map { |item| row(item, user, sources[item.agenda_id]) }
    end

    # One handle shape for every occurrence, whether or not it has been written
    # down yet. `display_id` is `p-<schedule>-<date>` for one that hasn't, and
    # every door that takes an id — `AgendaItem.locate_for_user`,
    # `edit_agenda_item` — accepts it exactly like a number.
    #
    # It used to hand back `#s<schedule_id>` and say so, and the whole apparatus
    # around that told the model an occurrence past the materialize window
    # could only be changed as a SERIES. That is how the calendar happens to be
    # stored; the person looking at their Tuesday cannot see it and should not
    # be asked to care.
    def handle(item)
      item.display_id.present? ? "##{item.display_id}" : "#new"
    end

    def row(item, user, source=nil)
      local = item.start_at.in_time_zone(user.timezone)
      when_str = item.all_day ? local.strftime("%a %b %-e, %Y (all day)") : local.strftime("%a %b %-e, %Y at %-I:%M%P")
      parts = [handle(item), item.name, when_str.sub(":00", "")]
      parts << "until #{clock(item.end_at, user)}" if ends_later?(item)
      # When they are back through the door, which for somebody else's item is
      # the ONLY figure on it that is about the asker's day. Prod 5266: "I want
      # to leave once Chelsea gets back from her yoga that day" - the search
      # found the yoga and handed back a start time and nothing else, so Byte
      # asked him for an end time the app had, and then for a drive home it had
      # too. Both were one line away the whole time.
      parts << "home by #{clock(item.home_at, user)}" if item.home_at
      parts << "on #{item.agenda&.name}" if item.agenda&.name.present?
      parts << "#{source[:owner]}'s, not theirs" if source && source[:mine] == false
      parts << "repeats" if item.agenda_schedule_id.present?
      parts.compact.join(" · ")
    end

    # An end worth printing: a real span, on a timed item. A task carries an
    # end equal to its start and an all-day covers the date already.
    def ends_later?(item)
      return false if item.all_day || item.end_at.blank? || item.start_at.blank?

      item.end_at > item.start_at
    end

    def clock(time, user)
      return nil if time.blank?

      time.in_time_zone(user.timezone).strftime("%-I:%M%P").sub(":00", "")
    end
  end
end
