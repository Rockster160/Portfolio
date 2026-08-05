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

      { items: items, total: scope.count, sources: sources }
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

    def row(item, user, source=nil)
      local = item.start_at.in_time_zone(user.timezone)
      when_str = item.all_day ? local.strftime("%a %b %-e, %Y (all day)") : local.strftime("%a %b %-e, %Y at %-I:%M%P")
      parts = ["##{item.id}", item.name, when_str.sub(":00", "")]
      parts << "on #{item.agenda&.name}" if item.agenda&.name.present?
      parts << "#{source[:owner]}'s, not theirs" if source && source[:mine] == false
      parts.compact.join(" · ")
    end
  end
end
