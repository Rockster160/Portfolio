module Jarvis::Times
  module_function

  def extract_time(words, chronic_opts={})
    rx = Jarvis::Regex
    words = words.gsub(rx.words(:later), "today")
    day_words = (Date::DAYNAMES + Date::ABBR_DAYNAMES + [:today, :tomorrow, :yesterday]).map { |w| w.to_s.downcase.to_sym }
    day_words_regex = rx.words(day_words)
    time_words = [:second, :minute, :hour, :day, :week, :month, :year]
    time_words_regex = rx.words(time_words, suffix: "s?")
    time_str = words[/\b(in) (\d+|an?) #{time_words_regex}/]
    time_str ||= words[/(#{day_words_regex} )?\b(at) \d+:?\d*( ?(am|pm))?( #{day_words_regex})?/]
    time_str ||= words[/\d+ #{time_words_regex} \b(from now|ago)\b/]
    time_str ||= words[/((next|last) )?#{day_words_regex}/]

    pre_sub = time_str

    # Need to clean up a little bit for Chronic syntax
    time_str = time_str.to_s.gsub(/ ?\b(at)\b ?/, " ")
    time_str = time_str.to_s.gsub(/\b(?:in) an? (#{time_words_regex})/, 'in 1 \1')
    time_str = time_str.gsub(/(.+)(#{day_words_regex})/) do |found|
      "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
    end

    [pre_sub, safe_date_parse(time_str.squish, chronic_opts)]
  end

  def safe_date_parse(timestamp, chronic_opts={})
    Chronic.time_class = ::Time.zone
    Chronic.parse(timestamp, chronic_opts)
  end
end
