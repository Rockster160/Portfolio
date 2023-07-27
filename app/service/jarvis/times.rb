module Jarvis::Times
  module_function

  def extract_time(words, chronic_opts={})
    rx = Jarvis::Regex
    words = words.gsub(rx.words(:later), "today")
    month_words = Date::MONTHNAMES + Date::ABBR_MONTHNAMES
    month_words_regex = rx.words(month_words)
    day_words = (Date::DAYNAMES + Date::ABBR_DAYNAMES + [:today, :tomorrow, :yesterday, :morning, :night, :afternoon, :evening, :tonight]).map { |w| w.to_s.downcase.to_sym }
    day_words_regex = rx.words(day_words)
    time_words = [:second, :minute, :hour, :day, :week, :month, :year]
    time_words_regex = rx.words(time_words, suffix: "s?")
    time_str = words[/\b(in) (\d+|an?) #{time_words_regex}/]
    # Chronic doesn't like "in an hour and 20 minutes"
    # time_str = words[/\b(in) (\d+|an?) #{time_words_regex}( (and )?\d+( #{time_words_regex})?)?/]
    time_str ||= words[/(\bon )?(#{month_words_regex} \d{1,2}(\w{2})?(,? '?\d{2,4})? )?((in the )?(#{day_words_regex} ?)+ )?\b(at) \d+:?\d*( ?(am|pm))?( (#{day_words_regex} ?)+)?/]
    time_str ||= words[/(\bon )?#{month_words_regex} \d{1,2}(\w{2})?(,? '?\d{2,4})?/]
    time_str ||= words[/(\bon )?\d{1,2}\/\d{1,2}(\/(\d{2}|\d{4})\b)?/]
    time_str ||= words[/in the #{day_words_regex}/]
    time_str ||= words[/(\d+|an?) #{time_words_regex} \b(from now|ago)\b/]
    time_str ||= words[/((next|last) )?(#{day_words_regex} ?)+/]

    pre_sub = time_str

    # Need to clean up a little bit for Chronic syntax
    time_str = time_str.to_s.gsub(/an? (#{time_words_regex})/, '1 \1')
    time_str = time_str.gsub(/^(.*?)(at \d+(?::\d+)?(?: ?(?:a|p)m)?)(.*?)$/) do |found| # If two day words are found here, only 1 is moved to the front
      "#{Regexp.last_match(1)} #{Regexp.last_match(3)} #{Regexp.last_match(2)}"
    end
    time_str = time_str.to_s.gsub(/ ?\b(at|on)\b ?/, " ")

    [pre_sub, safe_date_parse(time_str.squish, chronic_opts)]
  end

  def safe_date_parse(timestamp, chronic_opts={})
    opts = chronic_opts.reverse_merge(ambiguous_time_range: 8)
    ::Chronic.time_class = ::ActiveSupport::TimeZone.new("Mountain Time (US & Canada)")
    ::Chronic.parse(timestamp, opts).then { |time|
      next if time.nil?
      skip = timestamp.match?(/(a|p)m/) ? 24.hours : 12.hours
      time += skip while chronic_opts[:context] == :future && time < Time.current
      time -= skip while chronic_opts[:context] == :past && time > Time.current
      time
    }
  end
end
