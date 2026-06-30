module AgendaTravelChain
  # Parses travel-related override tokens out of an event's notes. Tokens are
  # anchored to the start of a line (case-insensitive) so free-form prose
  # elsewhere in the notes never gets confused for a directive.
  #
  # Recognized forms:
  #   nonav                      → bool: treat the event as if it had no location
  #   notme                      → bool: kick the car / build the trip silently
  #   before:Foo,Bar,"3rd, St"   → array of waypoints inserted on the incoming
  #                                 leg. Each entry may carry a trailing dwell
  #                                 duration ("Costco 15m", "Office 1h30m");
  #                                 the duration is the time the user plans to
  #                                 spend at that stop. Parsed shape:
  #                                 `[{ location:, dwell_seconds: }, …]`.
  #   after:Foo 10m,Bar          → array of waypoints on the outgoing leg.
  #                                 Same dwell syntax as `before:`.
  #   from:123 Main St           → string: explicit start of the incoming drive
  #                                 (overrides home / predecessor); also breaks
  #                                 the travel chain into this event since it's
  #                                 explicitly coming from elsewhere
  #   to:Greens Lake Campground  → string: explicit POST-event destination — the
  #                                 user is leaving the event's location and
  #                                 driving here. Adds a post-travel band AFTER
  #                                 the event (mirror of the incoming band) and
  #                                 acts as the outgoing endpoint for chain
  #                                 detection with the next event. Quoted
  #                                 segments preserve commas inside the value.
  #
  # before/after take a comma-separated list. from/to take a single address.
  # Quoted segments preserve commas ("3rd, St" stays one entry). Trailing
  # whitespace is stripped. Dwell tokens accept `Nm`, `Nh`, `NhMm`, `Nmin`,
  # `Nhr`, `Nhrs`, etc. Entries with no dwell parse as `dwell_seconds: 0`.
  module OverrideParser
    module_function

    EMPTY = {
      nonav:  false,
      notme:  false,
      before: [].freeze,
      after:  [].freeze,
      from:   nil,
      to:     nil,
    }.freeze

    def parse(notes)
      text = notes.to_s
      return EMPTY.dup if text.blank?

      {
        nonav:  text.match?(/^nonav\b/i),
        notme:  text.match?(/^notme\b/i),
        before: extract_list(text, "before"),
        after:  extract_list(text, "after"),
        from:   extract_single(text, "from"),
        to:     extract_single(text, "to"),
      }
    end

    def changed?(old_notes, new_notes)
      parse(old_notes) != parse(new_notes)
    end

    def extract_list(text, key)
      match = text[/^#{Regexp.escape(key)}:\s*([^\n]+)/i, 1]
      return [].freeze if match.blank?

      split_csv(match).map { |raw| parse_waypoint(raw) }.freeze
    end

    # Splits a waypoint entry into `{location:, dwell_seconds:}`. Trailing
    # tokens like `10m`, `1h30m`, `2hrs`, `45min` are stripped off as the
    # dwell duration; everything before is the location text. Entries without
    # a recognizable trailing duration produce `dwell_seconds: 0`.
    #
    # Greedy on the suffix: `Costco 1h 30m` is one duration (90 min), not a
    # bare location named "Costco 1h" with a 30m dwell.
    DURATION_SUFFIX_RE = /\A(.+?)\s+((?:\d+\s*(?:h(?:ours?|rs?)?|m(?:in(?:utes?)?)?)\s*)+)\z/i
    DURATION_TOKEN_RE  = /(\d+)\s*([hm])/i
    private_constant :DURATION_SUFFIX_RE, :DURATION_TOKEN_RE

    def parse_waypoint(raw)
      stripped = raw.to_s.strip
      return { location: "", dwell_seconds: 0 }.freeze if stripped.empty?

      if (m = stripped.match(DURATION_SUFFIX_RE))
        seconds = m[2].scan(DURATION_TOKEN_RE).sum { |n, unit|
          n.to_i * (unit.downcase == "h" ? 3600 : 60)
        }
        { location: m[1].strip, dwell_seconds: seconds }.freeze
      else
        { location: stripped, dwell_seconds: 0 }.freeze
      end
    end

    # Single-value tokens (from:/to:) — strip surrounding quotes if the entire
    # value was quoted, but otherwise keep punctuation/commas intact so a full
    # street address survives unmangled.
    def extract_single(text, key)
      match = text[/^#{Regexp.escape(key)}:\s*([^\n]+)/i, 1]
      return nil if match.blank?

      stripped = match.strip
      if stripped.start_with?('"') && stripped.end_with?('"') && stripped.length >= 2
        stripped = stripped[1..-2]
      end
      stripped.presence
    end

    # Split on commas, but keep "double quoted" segments together so addresses
    # like `"123 Main St, Apt 4"` survive without being mangled.
    def split_csv(str)
      out = []
      buf = +""
      in_quote = false
      str.each_char do |ch|
        if ch == '"'
          in_quote = !in_quote
        elsif ch == "," && !in_quote
          out << buf.strip
          buf = +""
        else
          buf << ch
        end
      end
      out << buf.strip
      out.reject(&:empty?)
    end
  end
end
