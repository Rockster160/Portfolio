module Buddy
  # Builds the seed instruction a recipient's Buddy turns into a warm,
  # in-character heads-up when someone adds or changes something on a shared
  # agenda (the "Notify others" checkbox on the add/edit forms). Mirrors
  # WatchMatcher#cross_user_seed: the seed tells the recipient's Byte/Moss
  # WHAT happened plus the non-standard details; the visible message is
  # whatever their Buddy composes from it, in their own voice.
  #
  # Handles both an AgendaItem (one-off / occurrence) and an AgendaSchedule
  # (a brand-new recurring event, created through the schedules endpoint).
  module AgendaBriefing
    module_function

    def seed(source:, actor:, recipient:, action:)
      case source
      when AgendaItem     then item_seed(source, actor, recipient, action)
      when AgendaSchedule then schedule_seed(source, actor, recipient, action)
      end
    end

    def item_seed(item, actor, recipient, action)
      details = detail_lines(
        when_text: item_when(item, recipient),
        location:  item.location,
        notes:     item.notes,
        extra:     [travel_line(item)].compact,
      )
      wrap(
        actor: actor, recipient: recipient, agenda: item.agenda,
        action: action, kind_word: item_kind_word(item), name: item.name, details: details
      )
    end

    def schedule_seed(schedule, actor, recipient, action)
      details = detail_lines(
        when_text: schedule_when(schedule),
        location:  schedule.location,
        notes:     schedule.notes,
        extra:     ["Repeats: #{recurrence_phrase(schedule)}"],
      )
      wrap(
        actor: actor, recipient: recipient, agenda: schedule.agenda,
        action: action, kind_word: "recurring #{schedule.kind}", name: schedule.name, details: details
      )
    end

    # ---- shared framing ----

    def wrap(actor:, recipient:, agenda:, action:, kind_word:, name:, details:)
      verb  = action.to_sym == :created ? "added" : "changed"
      who   = actor.first_name
      body  = "#{who} just #{verb} #{event_phrase(agenda, actor, recipient, kind_word)}: \"#{name}\"."
      body += "\n#{details}" if details.present?
      "#{body}\n\nGive #{recipient.first_name} a warm heads-up in your own voice — this is #{who}'s own " \
        "plan, not #{recipient.first_name}'s, so frame it as #{who}'s (\"#{who} added…\"), never as something " \
        "on #{recipient.first_name}'s own schedule. Just an FYI, nothing to confirm or act on. Lead with what " \
        "actually matters (the when/where and anything unusual)."
    end

    # Scope the event to whose calendar it lives on, WITHOUT naming the
    # calendar (its name is usually just the owner's handle — "Chelsea's
    # Alchemibluum calendar" is redundant). The actor's own calendar reads
    # "on their own calendar" (the recipient's Buddy renders the right
    # pronoun since it knows both people); the recipient's own reads "on your
    # calendar"; anything jointly-owned is simply "a shared <kind>".
    def event_phrase(agenda, actor, recipient, kind_word)
      if agenda.user_id == recipient.id
        "a #{kind_word} on your calendar"
      elsif agenda.user_id == actor.id
        "a #{kind_word} on their own calendar"
      else
        "a shared #{kind_word}"
      end
    end

    def detail_lines(when_text:, location:, notes:, extra: [])
      lines = []
      lines << "When: #{when_text}" if when_text.present?
      lines << "Where: #{location.to_s.strip}" if location.to_s.strip.present?
      lines << "Note: #{notes.to_s.strip}" if notes.to_s.strip.present?
      extra.compact_blank.each { |line| lines << line }
      lines.map { |line| "- #{line}" }.join("\n")
    end

    # ---- item helpers ----

    def item_kind_word(item)
      item.event? ? "event" : item.kind.to_s
    end

    def item_when(item, recipient)
      zone  = recipient_zone(recipient)
      start = item.start_at.in_time_zone(zone)
      return "all day #{start.strftime("%A, %b %-d")}" if item.all_day?

      if item.end_at.present?
        finish = item.end_at.in_time_zone(zone)
        "#{start.strftime("%A, %b %-d at %-l:%M %p")}–#{finish.strftime("%-l:%M %p")}"
      else
        start.strftime("%A, %b %-d at %-l:%M %p")
      end
    end

    # Best-effort travel line. Populated only when the async travel-chain
    # sync has already stamped metadata["travel"] (the notify worker runs on
    # a short delay so it usually has by then); silently omitted otherwise.
    def travel_line(item)
      travel = item.metadata.is_a?(Hash) ? (item.metadata["travel"] || {}) : {}
      minutes = travel["travel_minutes"].to_i
      return nil if minutes <= 0

      leave = travel["leave_at"]
      if leave.present?
        zone = recipient_zone(item.user)
        "Travel: about #{minutes} min away — leave by #{Time.at(leave.to_i).in_time_zone(zone).strftime("%-l:%M %p")}"
      else
        "Travel: about #{minutes} min away"
      end
    end

    # ---- schedule helpers ----

    def schedule_when(schedule)
      return "all day" if schedule.all_day?

      # start_time is a tz-naive wall-clock column (see AgendaSchedule), so no
      # per-recipient conversion — it reads the same for everyone.
      time = schedule.start_time&.strftime("%-l:%M %p")
      start_on = schedule.starts_on&.strftime("%A, %b %-d")
      parts = []
      parts << "at #{time}" if time.present?
      parts << "starting #{start_on}" if start_on.present?
      parts.join(", ").presence
    end

    def recurrence_phrase(schedule)
      case schedule.freq.to_sym
      when :daily    then "every day"
      when :weekdays then "every weekday"
      when :weekly   then weekly_phrase(schedule)
      when :monthly  then "monthly"
      when :yearly   then "yearly"
      else "on a custom schedule"
      end
    end

    def weekly_phrase(schedule)
      days = Array(schedule.recurrence_data[:by_day]).map { |k| k.to_s[0, 3].capitalize }
      days.any? ? "weekly on #{days.join(", ")}" : "weekly"
    end

    def recipient_zone(user)
      ActiveSupport::TimeZone[user&.timezone.to_s] || Time.zone
    end
  end
end
