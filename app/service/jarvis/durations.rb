module Jarvis::Durations
  module_function

  # Minutes-per-unit. Singular and plural collapse to the same multiplier.
  UNIT_MINUTES = {
    "s"   => 1.0 / 60,
    "sec" => 1.0 / 60, "secs"    => 1.0 / 60,
    "second" => 1.0 / 60, "seconds" => 1.0 / 60,
    "m"   => 1, "min" => 1, "mins" => 1,
    "minute" => 1, "minutes" => 1,
    "h"   => 60, "hr" => 60, "hrs" => 60,
    "hour" => 60, "hours" => 60,
  }.freeze

  # Longest units first so "hours" wins over "h" during regex assembly.
  UNIT_PATTERN = UNIT_MINUTES.keys.sort_by { |k| -k.length }.join("|").freeze
  QTY_PATTERN = '(?:\d+(?:\.\d+)?|an?|half)'.freeze

  # Single qty+unit token. Lookbehind blocks mid-word matches ("agent7m",
  # "roman"→"an m") but allows compound forms like "1h30m" by permitting
  # the unit letters h/m/s in the preceding position. Trailing lookahead
  # uses `(?![a-zA-Z])` (not `\b`) because `\b` doesn't fire between two
  # word chars — so `1h\b3` is false but `1h(?![a-zA-Z])3` works. Also
  # prevents truncating "hours" → "h" since `h` would be followed by `o`.
  NON_UNIT_LETTER = "a-gi-ln-rt-z".freeze
  END_BOUNDARY = '(?![a-zA-Z])'.freeze
  # Qty→unit gap: numeric qty may abut the unit ("1h", "1.5m"); word qty
  # ("a", "an", "half") MUST be separated by whitespace, so "Sam"/"ham"/
  # "9am"/"I am ..." can't be misread as `qty="a", unit="m"`. The
  # `(?<=\d)` lookbehind admits the digit-adjacent case at zero width; the
  # `\s+` branch handles every other valid form ("a min", "half hour").
  QTY_UNIT_GAP = '(?:(?<=\d)|\s+)'.freeze
  ATOM_RX = /(?<![#{NON_UNIT_LETTER}])(?<qty>#{QTY_PATTERN})#{QTY_UNIT_GAP}(?<unit>#{UNIT_PATTERN})#{END_BOUNDARY}/i
  STRIP_RX = /(?:\bfor\s+)?(?<![#{NON_UNIT_LETTER}])#{QTY_PATTERN}#{QTY_UNIT_GAP}(?:#{UNIT_PATTERN})#{END_BOUNDARY}\s*/i

  # Total minutes across all qty+unit atoms in the text. "1h 30m" → 90.
  # Returns 0 if nothing matches; rounded to the nearest minute.
  def extract(text)
    return 0 if text.to_s.empty?

    minutes = 0.0
    text.to_s.scan(ATOM_RX) do |qty, unit|
      n = case qty.downcase
          when "a", "an" then 1
          when "half"    then 0.5
          else qty.to_f
          end
      minutes += n * UNIT_MINUTES[unit.downcase]
    end
    minutes.round
  end

  # Leftover text after every duration atom (and an optional leading "for")
  # is removed. Lets callers pull duration out of a phrase and keep the rest.
  def strip(text)
    text.to_s.gsub(STRIP_RX, " ").squeeze(" ").strip
  end
end
