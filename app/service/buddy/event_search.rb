module Buddy
  # One person's ActionEvents, searched with the app's own query syntax — the
  # same `query` scope the events page and Jil's `ActionEvent.search` use, so a
  # filter that works in either of those works here too.
  #
  # `query` builds its SQL against `unscoped` (see ApplicationRecord), which
  # DROPS whatever relation it was called on. Ownership and the time window are
  # therefore re-applied after it, never before — skipping that is how a search
  # reaches another household member's log.
  module EventSearch
    module_function

    DEFAULT_DAYS = 14
    MAX_DAYS     = 730
    LIMIT        = 15

    # `names` is for callers that already know which events they want
    # (Buddy::PrintHistory), leaving `query` free to mean what the person said.
    def call(user:, query: nil, days: DEFAULT_DAYS, limit: LIMIT, names: nil)
      window = window_for(query, days)
      scope  = filtered(user, query)
      scope  = scope.where(user_id: user.id, timestamp: window..)
      scope  = scope.where(name: Array.wrap(names).map(&:to_s)) if names.present?

      { events: scope.order(timestamp: :desc).limit(limit).to_a, total: scope.count }
    end

    # A `timestamp` term in the query means the QUERY owns the range, and `days`
    # steps out of the way.
    #
    # These used to be ANDed, and the default is fourteen. "How much Celsius did
    # I drink last month vs this one?" came back "I couldn't find any Celsius
    # entries to total up" against fifty-eight of them, because the query said
    # `timestamp>2026-07-01 timestamp<2026-08-01` and the window said nothing
    # older than two weeks. Every row was excluded by an argument the person
    # never gave and the model had no reason to raise — the tool's own
    # description says a timestamp bound is the ALTERNATIVE to widening `days`.
    #
    # An upper bound alone is the same trap from the other end: `timestamp<` a
    # month ago intersects a fourteen-day floor to nothing at all.
    TIMESTAMP_TERM_RX = /\btimestamp\s*[:<>=]/i

    def window_for(query, days)
      return MAX_DAYS.days.ago if query.to_s.match?(TIMESTAMP_TERM_RX)

      days.to_i.clamp(1, MAX_DAYS).days.ago
    end

    # `timestamp:today` is what the model reaches for, and the parser has no
    # word for it: the term produces NO SQL and vanishes, leaving a query that
    # answers a broader question than the one asked, in silence. Same failure as
    # the `:>` spelling below, and the same reason to fix it here rather than
    # hope nobody writes it.
    #
    # Resolved in the PERSON's zone, never the server's. Time.zone is UTC
    # app-wide and their day starts six hours later, so at 9pm Denver the two
    # calendars disagree about what "today" is — which is exactly when somebody
    # is most likely to be asking about it.
    RELATIVE_DAYS = { "today" => 0, "yesterday" => -1, "tomorrow" => 1 }.freeze
    RELATIVE_RX   = /(?<=timestamp)(?<op>[:<>=]{1,2})(?<word>today|yesterday|tomorrow)\b/i

    def dated(query, user)
      zone = ActiveSupport::TimeZone[user.timezone.to_s] || Time.zone
      today = Time.current.in_time_zone(zone).to_date

      query.gsub(RELATIVE_RX) { |_|
        match = Regexp.last_match
        "#{match[:op]}#{(today + RELATIVE_DAYS.fetch(match[:word].downcase)).iso8601}"
      }
    end

    # A comparison is written `timestamp>2026-07-01`, but `timestamp:>2026-07-01`
    # is what anyone reaching for it types first — and the parser reads that as
    # a single `:>` operator, which matches nothing it knows and gets DROPPED.
    # The query then runs unbounded and answers a question nobody asked, in
    # silence. Cheaper to accept both spellings than to catch it downstream.
    COLON_COMPARISON_RX = /:(?=[<>=])/

    # Anything the person could type into the events page. A query the parser
    # chokes on falls back to a plain contains-match rather than failing the
    # turn: the model writes these, and a stray bracket shouldn't cost them the
    # lookup.
    def filtered(user, query)
      q = dated(query.to_s.strip.gsub(COLON_COMPARISON_RX, ""), user)
      return user.action_events if q.blank?

      user.action_events.query(q)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::EventSearch] unparseable query #{q.inspect}: #{e.class}: #{e.message}")
      user.action_events.search(q)
    end

    # One line per hit. The id leads because it's what edit_event and
    # delete_event take, and acting on what turned up is the point of looking.
    def rows(events, user)
      events.map { |event| row(event, user) }
    end

    def row(event, user)
      notes = event.notes.to_s.strip
      named = notes.present? ? "#{event.name} (#{notes.truncate(40)})" : event.name.to_s
      "##{event.id} · #{named} · #{when_phrase(event.timestamp, user)}"
    end

    def when_phrase(time, user)
      time.in_time_zone(user.timezone).strftime("%a %-m/%-d %-I:%M%P").sub(":00", "")
    end
  end
end
