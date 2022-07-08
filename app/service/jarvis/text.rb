module Jarvis::Text
  module_function

  IM_HERE_RESPONSES = [
    "For you sir, always.",
    "At your service, sir.",
    "Yes, sir.",
    "Good --time--, sir"
  ]
  APPRECIATE_RESPONSES = [
    "You're welcome, sir."
  ]

  def im_here
    decorate(IM_HERE_RESPONSES.sample)
  end

  def appreciate
    decorate(APPRECIATE_RESPONSES.sample)
  end

  def rephrase(words)
    reversed_words = words.gsub(/\b(my)\b/i, "your")
    reversed_words = reversed_words.gsub(/\b(me|i)\b/i, "you")
    reversed_words = reversed_words.gsub(/[^a-z0-9]*$/, "").squish
    reversed_words = reversed_words.tap { |line| line[0] = line[0].to_s.downcase }
  end

  # ============== Support ============

  def decorate(words)
    words = words.gsub(/--time--/) { current_time_decoration }
  end

  def current_time_decoration
    case Time.current.hour
    when 0..4, 19..25 then :evening
    when 5..12 then :morning
    when 12..18 then :afternoon
    end
  end
end
