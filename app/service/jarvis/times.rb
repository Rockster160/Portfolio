# NOT WORKING:
# ... on the 16th

module Jarvis::Times
  module_function

  def extract_time(words, chronic_opts={})
    rx = Jarvis::Regex
    drx = /\d+(?:\.\d+)?/
    words = words.gsub(rx.words(:later), "today")
    month_words = Date::MONTHNAMES + Date::ABBR_MONTHNAMES
    month_words_regex = rx.words(month_words)
    day_words = (Date::DAYNAMES + Date::ABBR_DAYNAMES + [:today, :tomorrow, :yesterday, :morning, :night, :afternoon, :evening, :tonight]).map { |w| w.to_s.downcase.to_sym }
    day_words_regex = rx.words(day_words)
    time_words = [:second, :minute, :hour, :day, :week, :month, :year]
    rel_words_regex = rx.words(time_words, suffix: "s?")
    iso8601_regex = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}-\d{2}:\d{2}/
    and_some = /(?: (?:and )?(?:an? )?(#{drx})?(?: ?\bhalf\b ?)?(?: (#{rel_words_regex}))?)?/
    time_words_regex = /(#{rel_words_regex})#{and_some}/
    time_str = words[/\bin (#{drx}|an?) #{time_words_regex}(?: ?(#{drx}))?/]
    time_str ||= words[/\bin (#{drx}|an?)#{and_some}(#{rel_words_regex})/]
    time_str ||= words[/(\b(?:on|next|last) )?(#{month_words_regex} \d{1,2}(\w{2})?(,? '?\d{2,4})? )?((in the )?(#{day_words_regex} ?)+ )?\b(at) \d+:?\d*( ?(am|pm))?( (#{day_words_regex} ?)+)?/]
    time_str ||= words[/(\b(?:on|next|last) )?#{month_words_regex} \d{1,2}(\w{2})?(,? '?\d{2,4})?/]
    time_str ||= words[/(\b(?:on|next|last))(?:^| )?\d{1,2}\/\d{1,2}(\/(\d{2}|\d{4})\b)?/]
    time_str ||= words[/(\b(?:on|next|last))(?:^| )#{day_words_regex}/]
    time_str ||= words[/in the #{day_words_regex}/]
    time_str ||= words[/(#{drx}|an?) #{time_words_regex} \b(from now|ago)\b/]
    time_str ||= words[/((next|last) )?(#{day_words_regex} ?)+/]
    time_str ||= words[/(\bat )(#{iso8601_regex} ?)/]

    pre_sub = time_str

    # Need to clean up a little bit for Chronic syntax
    time_str = time_str.to_s.gsub(/an? (#{time_words_regex})/, '1 \1') # an hour → 1 hour
    time_str = time_str.gsub(/^(.*?)(at \d+(?::\d+)?(?: ?(?:a|p)m)?)(.*?)$/) { |_found|
      # If two day words are found here, only 1 is moved to the front
      "#{Regexp.last_match(1)} #{Regexp.last_match(3)} #{Regexp.last_match(2)}"
    }
    time_str = time_str.gsub(/(#{drx})( #{time_words_regex})? and (?:a )?half/, '\1.5 \2') # 3 and a half hours → 3.5 hours
    time_str = time_str.to_s.gsub(/ ?\b(at|on)\b ?/, " ").squish
    [pre_sub, safe_date_parse(time_str.squish, chronic_opts)].then { |pre_text, parsed_time|
      if parsed_time.present?
        parsed_time += 12.hours if time_str.include?("morning") && parsed_time.hour == 21
      else
        m = time_str.match(/(#{drx})\s+(#{rel_words_regex})#{and_some}/)
        parsed_time = m&.to_a&.then { |_, n1, t1, n2, t2|
          interval = (n1 || 1).to_f.send(t1 || :hours)
          interval += n2.to_i.send(t2 || :minutes)
          interval = -interval if chronic_opts[:context] == :past
          Time.current + interval
        }
      end

      [pre_text, parsed_time]
    }
  end

  def safe_date_parse(timestamp, chronic_opts={})
    # Force override the context if using `in x time` or `x time ago`
    chronic_opts[:context] = :past if timestamp.match?(/\b(ago)\s*$/)
    chronic_opts[:context] ||= :future if timestamp.match?(/^\s*in\b/)
    chronic_opts[:context] ||= :future if timestamp.match?(/\b(from now)\s*$/)
    opts = chronic_opts.reverse_merge(ambiguous_time_range: 8)
    ::Chronic.time_class = ::ActiveSupport::TimeZone.new("Mountain Time (US & Canada)")
    ::Chronic.parse(timestamp, opts)&.then { |time|
      skip = timestamp.match?(/(a|p)m/) ? 24.hours : 12.hours
      time += skip while chronic_opts[:context] == :future && time < Time.current
      time -= skip while chronic_opts[:context] == :past && time > Time.current
      time
    }
  rescue StandardError => e
    ### Rescue various Chronic errors, specifically
    # -- https://github.com/mojombo/chronic/issues/415
    #   ::Chronic.parse("3 hours and 30 minutes before")
    #   → NoMethodError: undefined method `start=' for nil:NilClass
  end
end
