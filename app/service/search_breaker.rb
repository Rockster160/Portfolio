module SearchBreaker
  module_function

  RX = {
    quot_str:        /^\"(.*?)\"$/,
    single_quot_str: /^\'(.*?)\'$/,
    rx_str:          /^\/(.*?)\/$/,
    paren_wrap:      /^\((.*?)\)$/,
    start:           /(?:^|\b)/,
  }

  def unwrap(str, parens: true, quotes: true)
    str = str.gsub(/(?:#{RX[:quot_str]})|(?:#{RX[:single_quot_str]})/, '\1') if quotes
    str = str.gsub(RX[:paren_wrap], '\1') if parens
    str
  end

  def call(str, delimiters={})
    str = str.dup
    tr = ::NewTokenizer.new(str)
    delims_with_aliases = delimiters.each_with_object([]) { |(key, delims), arr|
      ::Array.wrap(delims).each { |item| arr << [key, item] }
    }

    out = {
      keys: {},
      vals: {},
    }

    if delims_with_aliases.none? { |dk, d| str.include?(d) }
      return { keys: { str => {} } }
    end

    delim_regex = delim_escaped_regex(delims_with_aliases)
    tr.tokenized_text.split(/\s+/).each_with_object(out) { |tz_piece, obj|
      piece = tr.untokenize(tz_piece)
      next (obj[:keys][piece] ||= {}) unless tz_piece.match?(delim_regex)

      tz_key, delim, tz_val = tz_piece.split(delim_regex, 2)
      key = tr.untokenize(tz_key)
      val = tr.untokenize(tz_val)
      delim_key = delims_with_aliases.find { |dk, d| delim.downcase == d.downcase }[0]

      key, val = [key, val].map { |part| unwrap(part, quotes: false) }
      val = broken_or_val(val, delimiters) # Recursive search breaker
      key, val = [key, val].map { |part| part.is_a?(::String) ? unwrap(part, parens: false) : part }

      if key.blank?
        out[:vals][delim_key] ||= []
        out[:vals][delim_key] << val
      else
        out[:keys][key] ||= {}
        out[:keys][key][delim_key] ||= []
        out[:keys][key][delim_key] << val
      end
    }.compact_blank
  end

  def delim_escaped_regex(delimiters)
    sorted_delims = delimiters.sort_by { |dk, d| -d.length } # Longest first
    sorted_delims.map { |dk, d|
      ::Regexp.escape(d)
    }.join("|").then { |delims|
      ::Regexp.new(/#{RX[:start]}(#{delims})/i)
    }
  end

  def broken_or_val(val, delimiters)
    broken = ::SearchBreaker.call(val, delimiters)

    if broken[:vals].blank?
      if broken[:keys].keys == [val]
        return val if broken[:keys][val] == {}
      end
    end
    broken
  end
end
