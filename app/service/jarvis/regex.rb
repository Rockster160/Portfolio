module Jarvis::Regex
  module_function

  UUID = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}/

  def match_data(str, rx)
    # "Open the garage", "/(?<direction>open|close|toggle)( (?:the|my))? garage/"
    rx = rx[/^\/(.*?)\/[img]*$/, 1] || rx # TODO: Actually use the flags
    md = str.match(Regexp.new("^#{rx}$", Regexp::IGNORECASE | Regexp::MULTILINE))
    return if md.nil?

    {
      match_list: md.to_a,
      named_captures: md.named_captures.symbolize_keys
    }
  end

  def match_any_words?(str, *words)
    return false if words.flatten.none?

    str.match?(words(words))
  end

  def uuid?(str)
    str.to_s.match?(/\A#{UUID.source}\z/)
  end

  def words(*words, suffix: nil, prefix: nil)
    Regexp.new("(?:\\b#{prefix}(?:#{words.flatten.compact.uniq.join('|')})#{suffix}\\b)", :i)
  end

  def address
    street_name_words = [
      :highway,
      :autoroute,
      :north,
      :n,
      :south,
      :s,
      :east,
      :e,
      :west,
      :w,
      :avenue,
      :lane,
      :road,
      :route,
      :drive,
      :boulevard,
      :circle,
      :street,
      :cir,
      :blvd,
      :hway,
      :st,
      :ave,
      :ln,
      :rd,
      :hw,
      :dr,
    ]

    /(suite|ste)?\s*?[0-9]+[\s\w.,]*#{words(street_name_words)}([\s.,-]*[a-z0-9]*)*/im
  end
end
