module SearchBreaker
  module_function

  RX = {
    quot_str: /^"(.*?)"$/,
    single_quot_str: /^'(.*?)'$/,
    rx_str: /^\/(.*?)\/$/,
    paren_wrap: /^:*\((.*?)\)$/,
    start: /(?:^|\b)/,
  }

  def call(str, delimiters={})
    str = str.dup
    tr = Tokenizer.new(str)
    aliases = delimiters.delete(:aliases)

    delims_with_aliases = delimiters.to_a
    aliases&.each do |actual, ali|
      delims_with_aliases << [delimiters.key(ali), actual.to_s]
    end

    out = {
      keys: {},
      vals: {},
    }

    if delims_with_aliases.none? { |dk, d| str.include?(d) }
      return { keys: { str => {} } }
    end

    delim_regex = delim_escaped_regex(delims_with_aliases)
    tokenized_split(str, tr).each_with_object(out) { |piece, obj| # Breaks each whitespace chunk
      next (obj[:keys][piece] ||= {}) unless piece.match?(delim_regex)

      key, delim, val = piece.split(delim_regex, 2)
      delim_key = delims_with_aliases.find { |dk, d| delim.downcase == d.downcase }[0]
      key, val = [key, val].map { |part|
        part.gsub(RX[:quot_str], '\1').gsub(RX[:single_quot_str], '\1').gsub(RX[:rx_str], '\1')
      }
      if val.match?(RX[:paren_wrap])
        val = val.gsub(RX[:paren_wrap], '\1')
      end

      val = broken_or_val(val, delimiters) # Recursive search breaker

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
      Regexp.escape(d)
    }.join("|").then { |delims|
      Regexp.new(/#{RX[:start]}(#{delims})/i)
    }
  end

  def broken_or_val(val, delimiters)
    broken = SearchBreaker.call(val, delimiters)

    if broken[:vals].blank?
      if broken[:keys].keys == [val]
        return val if broken[:keys][val] == {}
      end
    end
    broken
  end

  def tokenized_split(str, tr=nil)
    str = str.dup
    rebuild = !tr.nil?
    tr ||= Tokenizer.new(str)
    tr.tokenize!(str, /\\./)
    tr.tokenize!(str, /"([^"\\]|\\.)*"/)
    tr.tokenize!(str, /'([^'\\]|\\.)*'/)
    tr.tokenize!(str, /\/([^\/\\]|\\.)*\//)
    tr.tokenize!(str, /\(.*?\)/)

    return str.split(/\s/) unless rebuild

    str.split(/\s/).map { |piece| tr.untokenize!(piece) }
  end
end
