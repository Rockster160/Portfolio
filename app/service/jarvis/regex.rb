module Jarvis::Regex
  module_function

  def match_any_words?(str, *words)
    str.match?(words(words))
  end

  def words(*words)
    Regexp.new("\\b(?:#{words.flatten.join('|')})\\b", :i)
  end
end
