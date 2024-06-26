module SearchBreakMatcher
  module_function

  DELIMITERS = {
    contains:     ":",
    exact:        "::",
    not:          "!",
    not_contains: "!:",
    not_exact:    "!::",
    regex:        "~",
    or:           "OR",
    aliases: { # Figure out a way that allows an "aliases" delimiter. Just in case.
      or: "OR:", # Should probably reverse these so multiple aliases can point to one delim
    }
  }

  def call(str, data)
    breaker = SearchBreaker.call(str, DELIMITERS)

    return false if !data.is_a?(Hash) || data.keys.none?
    raise "Only 1 top level key allowed" unless data.keys.one?

    breaker_matches(breaker, data).any?
  rescue StandardError => e
    # binding.pry
  end
  # {data} -- ...key: key: key: "string"
  # data = { event: { data: { custom: { nested_key: "fuzzy_val thing" } } } }
  # {breaker} -- broken.keys & [:keys, :vals]
  #   keys: {{broken}, {broken}, ...}
  # {broken} -- broken.keys & [:contains, ...]
  #   {delim}: [{piece}, {piece}]
  # {delim} -- contains|exact|delims
  # {piece} -- [String, {breaker}]

  def breaker_matches(breaker, data, d=nil)
    if (breaker.is_a?(String) || breaker.is_a?(Symbol)) && d.present?
      return valstr_match(breaker, d, data)
    end

    # puts "\e[33mBreaker Matches: #{breaker} [#{d}] #{data}\e[0m"
    (breaker[:keys]&.filter_map { |val, broken| # val="event" && broken[:contains] = [{piece}]
      next false if d.present? && !valstr_match(val, d, data)

      top_match = broken.empty? && valstr_match(val, :contains, data)
      next top_match if top_match

      broken.filter_map { |delim, piece|
        case piece
        when Array then piece.filter_map { |nested_breaker| breaker_matches(nested_breaker, data, delim) }
        else valstr_match(val, delim, data)
        end
      }
    }&.flatten || []) + (breaker[:vals]&.filter_map { |delim, piece|
      # We have to do something with :or here!
      case piece
      when Array then piece.filter_map { |nested_breaker| breaker_matches(nested_breaker, data, delim) }
      when String, Symbol then valstr_match(piece, delim, data)
      else
        # binding.pry
      end
    }&.flatten || [])
  rescue StandardError => e
    # binding.pry
  end

  def valstr_match(val, delim, data) # val is a bottom-level string from the {broken} data
    data = data.to_s if data.is_a?(Symbol)
    return check_match?(val, delim, data) && data if data.is_a?(String)
    # Return back the first object that matches -- Might need to return the nested object?
    data&.find { |dkey, dvals|
      next true if check_match?(val, delim, dkey)

      case dvals
      when Hash
        dvals.find { |k,v|
          check_match?(val, delim, k) || valstr_match(val, delim, v)
        }
      when Array
        dvals.find { |dv| valstr_match(val, delim, dv) }
      when String # string to string -- Check if they match according to the delim
        check_match?(val, delim, dvals) && dvals
      else
        # binding.pry
      end
    }.tap { |a|
      # puts "\e[#{a ? 32 : 31}m#{val} [#{delim}] --#{data}\e[0m"
    } || false
  rescue StandardError => e
    # binding.pry
  end

  def check_match?(val, delim, str)
    val = val.to_s.downcase
    str = str.to_s.downcase
    case delim
    when :contains then str.include?(val)
    when :not_contains then !str.include?(val)
    when :exact then val == str
    when :not, :not_exact then val != str
    # when :regex then str.match?(regex)
    else false
    end.tap { |a|
      # puts "\e[#{a ? 32 : 31}m#{val} [#{delim}] #{str}\e[0m"
    }
  rescue StandardError => e
    # binding.pry
  end
end
