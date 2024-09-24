module Jarvis::Regex
  module_function

  def match_data(str, rx)
    # "Open the garage", "/(?<direction>open|close|toggle)( (?:the|my))? garage/"
    rx = rx[1..-2] if rx[/^\/(.*?)\/[img]*$/, 1] # TODO: Actually use the flags
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

    /(suite|ste)? ?[0-9]+[ \w.,]*#{words(street_name_words)}([ .,-]*[a-z0-9]*)*/i
  end
end
