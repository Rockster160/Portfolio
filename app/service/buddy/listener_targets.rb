module Buddy
  # A hand-written watch listener can be perfectly well-formed and still name
  # something that has never existed.
  #
  # `Jil::ListenerMatch.valid?` answers "could this ever fire in principle" -
  # is the scope real, are there terms. It cannot answer "is there a list
  # actually called this", and that is the failure people don't notice: prod
  # Aug 5 turned "I need to check the front flower bed daily" into a watch on
  # `item:list:name:/^Daily front flower bed check$/`. Well-formed, valid scope,
  # no such list. It sat there looking set and could never fire.
  #
  # The same failure has a second shape, and it's worse because the listener
  # points at a real key. `laundry:action:stop` names a scope that fires and an
  # `action` key that exists — and `laundry` has only ever been fired with
  # `action: "start"`, by a button press and a spoken command. Twice in one day
  # a watch was written on it (the washer, then the dryer), and both times it
  # validated and then sat silent. What the appliances actually report is
  # `hass-trigger`. So a value the scope has never once fired with is refused
  # too, off Buddy::TriggerShapes' observed values.
  #
  # Only names we can pin to ONE literal are checked. A loose pattern is a
  # pattern and gets the benefit of the doubt.
  module ListenerTargets
    module_function

    TERM_RX = {
      list:    /\A(?:item|list):list:name:(?<value>.+)\z/i,
      section: /\A(?:item|list):section:name:(?<value>.+)\z/i,
    }.freeze

    # `/^Name$/` - anchored both ends, nothing regex-ish inside, so it can only
    # ever match the one string.
    ANCHORED_RX = %r{\A/\^(?<name>[^\^$*+?()\[\]{}|\\/]+)\$/[imx]*\z}
    QUOTES      = ["\"", "'"].freeze

    # What this listener names that isn't there, phrased for the model, or nil
    # when everything it points at exists.
    def missing(listener, user:)
      return nil if listener.blank? || user.nil?

      scope = Jil::ListenerMatch.scope_of(listener)
      terms = Jil::ListenerMatch.terms(listener)
      terms.filter_map { |term| gap_in(term, user) || dead_value(term, scope, user) }.first
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ListenerTargets] check failed: #{e.class}: #{e.message}")
      nil
    end

    # A term filtering on a value this scope has never once fired with.
    #
    # Refuses only on positive evidence: `known_values` returns nil for a key
    # never recorded, or one with too many values to be an enum, and either way
    # the term passes. The whole point is that a wrong guess should FAIL LOUDLY
    # while there's still someone in the conversation to tell, instead of
    # looking set for a month.
    def dead_value(term, scope, user)
      text = term.to_s.strip
      # A regex or an ANY() set names a pattern, not a value.
      return nil if text.include?("/") || text.match?(/\bany\(/i)

      path, value = path_and_value(text, scope)
      return nil if path.blank? || value.blank?

      known = Buddy::TriggerShapes.known_values(user, scope, path)
      return nil if known.nil?
      # Lenient on purpose, and in the safe direction: a single colon compares
      # as a case-insensitive SUBSTRING, so anything that could satisfy either
      # comparison is left alone. Only a value that can match nothing is called.
      return nil if known.any? { |seen| matchable?(seen.to_s, value) }

      "#{scope} has only ever fired with #{path} of #{known.map(&:inspect).join(", ")}, " \
        "so nothing would ever match #{value.inspect}"
    end

    # `hass-trigger:device_name::Washer` -> ["device_name", "Washer"], and a
    # trailing term like `type::stop` -> ["type", "stop"]. Nested paths join up
    # the way Buddy::TriggerShapes records them (`list.name`).
    def path_and_value(term, scope)
      parts = term.split(/:+/).compact_blank
      parts.shift if parts.first.to_s.casecmp?(scope.to_s)
      return [nil, nil] if parts.length < 2

      [parts[0..-2].join("."), parts.last]
    end

    def matchable?(seen, value)
      seen.casecmp?(value) || seen.downcase.include?(value.downcase)
    end

    def gap_in(term, user)
      text = term.to_s.strip
      kind, match = TERM_RX.filter_map { |k, rx| [k, rx.match(text)] if rx.match(text) }.first
      return nil if match.nil?

      name, how = literal_name(match[:value])
      return nil if name.blank?
      return nil if names_for(kind, user).any? { |real| hit?(real, name, how) }

      "there is no #{kind} called #{name.inspect}"
    end

    # The name this term can only ever mean, plus HOW the listener compares it.
    # An anchored regex names one string; a bare or quoted value is matched as a
    # case-insensitive SUBSTRING, so `item:list:name:Claude` is satisfied by a
    # list called "Claude Notes" and demanding an exact row would reject a
    # perfectly good watch.
    def literal_name(value)
      raw = value.to_s.strip
      anchored = ANCHORED_RX.match(raw)
      return [anchored[:name].strip, :exact] if anchored
      # Any other regex is a pattern rather than a name - several things could
      # satisfy it, and refusing one on the grounds that nothing is spelled
      # exactly like the pattern would be wrong.
      return [nil, nil] if raw.start_with?("/")

      [QUOTES.reduce(raw) { |str, q| str.delete_prefix(q).delete_suffix(q) }.strip.presence, :contains]
    end

    def hit?(real, name, how)
      how == :exact ? real.casecmp?(name) : real.downcase.include?(name.downcase)
    end

    # Sections belong to lists, so any list of theirs carrying the name counts -
    # the listener usually pins the list separately in its own term.
    def names_for(kind, user)
      lists = user.ordered_lists
      scope = kind == :list ? lists : Section.where(list_id: lists.select(:id))
      scope.filter_map { |row| row.name.to_s.strip.presence }
    end
  end
end
