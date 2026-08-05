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

      Jil::ListenerMatch.terms(listener).filter_map { |term| gap_in(term, user) }.first
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ListenerTargets] check failed: #{e.class}: #{e.message}")
      nil
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
