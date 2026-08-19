# The `<anchor key><offset>` syntax, and nothing else.
#
#   sun:sunset                    the next one, whenever that is
#   sun:sunset-5m                 five minutes before the next one
#   trash:pickup+1h               an hour after the next one
#   sun:sunset[2026-08-19]-5m     five minutes before THAT one, and only that one
#
# Deliberately knows nothing about what any anchor MEANS or whether it exists -
# it only reads the shape. Which anchors are real is a question about the user's
# own data (see Anchor), so that a new one is something they create rather than
# something someone adds to a list in here.
#
# Documented for humans in docs/jil_anchors.md.
module AnchorExpression
  module_function

  # `<domain>:<event>`, an optional `[identifier]` pinning one occurrence, and an
  # optional signed offset that may chain units ("-1h30m").
  #
  # The identifier is bracket-delimited rather than colon-separated so nothing
  # has to be inferred: the colon already separates domain from event, and an
  # identifier is usually a date, so `sun:sunset:2026-08-19-5m` would have left
  # both the third colon and the trailing `-5m` ambiguous. Brackets end the
  # identifier explicitly, which means it can hold anything at all - dates,
  # hyphens, even something that looks like an offset.
  EXPRESSION = %r{
    \A(?<key>[a-z0-9_]+:[a-z0-9_]+)
    (?:\[(?<identifier>[^\[\]]+)\])?
    (?<offset>[+-](?:\d+[smhdw])+)?\z
  }xi

  # The key shape on its own. No cron is ever `word:word`, so matching this is
  # what separates "meant to be an anchor and got it wrong" from "not an anchor".
  KEY_SHAPED = /\A[a-z0-9_]+:[a-z0-9_]+/i

  OFFSET_PART = /(\d+)([smhdw])/i

  UNIT_SECONDS = { s: 1, m: 60, h: 3_600, d: 86_400, w: 604_800 }.freeze

  # => { key:, identifier:, offset_seconds: }, or nil when this isn't an anchor
  # expression at all (which is how CronParse tells it from a cron).
  def parse(str)
    match = EXPRESSION.match(str.to_s.strip)
    return nil unless match

    {
      key:            match[:key].downcase,
      identifier:     match[:identifier].presence,
      offset_seconds: parse_offset(match[:offset]),
    }
  end

  def shaped?(str)
    str.to_s.strip.match?(KEY_SHAPED)
  end

  def key_in(str)
    str.to_s.strip[KEY_SHAPED]&.downcase
  end

  def parse_offset(offset)
    return 0 if offset.blank?

    sign = offset.start_with?("-") ? -1 : 1
    secs = offset.scan(OFFSET_PART).sum { |num, unit|
      num.to_i * UNIT_SECONDS.fetch(unit.downcase.to_sym)
    }

    sign * secs
  end

  # nil when `str` is a well-formed expression. Otherwise a sentence about the
  # syntax - but only when it was plainly reaching for an anchor, so an ordinary
  # cron doesn't get told it's a bad one. Says nothing about whether the anchor
  # exists; that's Anchor's to answer.
  def complaint(str)
    str = str.to_s.strip
    return nil if parse(str)
    return nil unless shaped?(str)

    key = key_in(str)

    "couldn't read the offset in #{str.inspect}. Expected a sign, a number and " \
      "a unit - like #{key}-5m or #{key}+1h30m (units: s, m, h, d, w)"
  end
end
