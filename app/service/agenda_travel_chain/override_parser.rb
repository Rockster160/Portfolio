module AgendaTravelChain
  # Parses travel-related override tokens out of an event's notes. Tokens are
  # anchored to the start of a line (case-insensitive) so free-form prose
  # elsewhere in the notes never gets confused for a directive.
  #
  # Recognized forms:
  #   nonav                      → bool: treat the event as if it had no location
  #   notme                      → bool: kick the car / build the trip silently
  #   before:Foo,Bar,"3rd, St"   → array: waypoints inserted on the incoming leg
  #   after:Foo,Bar              → array: waypoints inserted on the outgoing leg
  #   from:123 Main St           → string: explicit start of the incoming drive
  #                                 (overrides home / predecessor); also breaks
  #                                 the travel chain into this event since it's
  #                                 explicitly coming from elsewhere
  #   to:Side entrance           → string: explicit end of the incoming drive
  #                                 (overrides the event's location). Quoted
  #                                 segments preserve commas inside the value.
  #
  # before/after take a comma-separated list. from/to take a single address.
  # Quoted segments preserve commas ("3rd, St" stays one entry). Trailing
  # whitespace is stripped.
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

      split_csv(match).freeze
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
