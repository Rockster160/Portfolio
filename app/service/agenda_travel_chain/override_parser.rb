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
  #
  # before/after take a comma-separated list. Quoted segments preserve commas
  # ("3rd, St" stays one waypoint). Trailing whitespace is stripped.
  module OverrideParser
    module_function

    EMPTY = {
      nonav:  false,
      notme:  false,
      before: [].freeze,
      after:  [].freeze,
    }.freeze

    def parse(notes)
      text = notes.to_s
      return EMPTY.dup if text.blank?

      {
        nonav:  text.match?(/^nonav\b/i),
        notme:  text.match?(/^notme\b/i),
        before: extract_list(text, "before"),
        after:  extract_list(text, "after"),
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
