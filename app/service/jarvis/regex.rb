module Jarvis::Regex
  module_function

  def match_any_words?(str, *words)
    return false if words.flatten.none?

    str.match?(words(words))
  end

  def words(*words, suffix: nil, prefix: nil)
    Regexp.new("(?:\\b#{prefix}(?:#{words.flatten.join('|')})#{suffix}\\b)", :i)
  end

  def address
    street_name_words = [
      :highway,
      :autoroute,
      :north,
      :south,
      :east,
      :west,
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
