module Jarvis::Regex
  module_function

  def match_any_words?(str, *words)
    str.match?(words(words))
  end

  def words(*words, suffix: nil, prefix: nil)
    Regexp.new("(?:\\b#{prefix}(?:#{words.flatten.join('|')})#{suffix}\\b)", :i)
  end
end
