class SearchBreakMatcher
  attr_accessor :regex_match_data

  DELIMITERS = {
    contains:     ":",
    exact:        "::",
    not:          "!",
    not_contains: ":!",
    not_exact:    "::!",
    regex:        "~",
    any:          "ANY",
    aliases: { # Figure out a way that allows an "aliases" delimiter. Just in case.
      any: "ANY:", # Should probably reverse these so multiple aliases can point to one delim
    }
  }

  def initialize(str, data, parent=nil)
    @parent = parent
    @regex_match_data = { match_list: [], named_captures: {} }
    @top_breaker = SearchBreaker.call(str, DELIMITERS)
    @top_data = data

    match?
  rescue StandardError => e
    raise unless Rails.env.production?
  end

  def match?
    @matched ||= begin
      return false if !@top_data.is_a?(Hash) || @top_data.keys.none?
      raise "Only 1 top level key allowed" unless @top_data.keys.one?

      breaker_matches(@top_breaker, @top_data).any?
    end
  end

  # {data} -- ...key: key: key: "string"
  # data = { event: { data: { custom: { nested_key: "fuzzy_val thing" } } } }
  # {breaker} -- broken.keys & [:keys, :vals]
  #   keys: {{broken}, {broken}, ...}
  # {broken} -- broken.keys & [:contains, ...]
  #   {delim}: [{piece}, {piece}]
  # {delim} -- contains|exact|delims
  # {piece} -- [String, {breaker}]

  def breaker_matches(breaker, data, passed_delim=nil)
    if (breaker.is_a?(String) || breaker.is_a?(Symbol)) && passed_delim.present?
      return valstr_match(breaker, passed_delim, data)
    end

    (breaker[:keys]&.filter_map { |val, broken| # val="event" && broken[:contains] = [{piece}]
      if passed_delim.present?
        data = valstr_match(val, passed_delim, data)
        next false if !data
      end

      top_match = broken.empty? && valstr_match(val, :contains, data)
      next top_match if top_match

      broken.filter_map { |delim, piece|
        case piece
        when Array then piece.filter_map { |nested_breaker| breaker_matches(nested_breaker, data, delim) }
        else valstr_match(val, delim, data)
        end
      }
    }&.flatten || []) + (breaker[:vals]&.filter_map { |delim, piece|
      case piece
      when Array then piece.filter_map { |nested_breaker| breaker_matches(nested_breaker, data, delim) }
      when String, Symbol then valstr_match(piece, delim, data)
      else
        raise "Unhandled piece class: #{piece.class}"
      end
    }&.flatten || [])
  rescue StandardError => e
    raise unless Rails.env.production?
  end

  def valstr_match(val, delim, data) # val is a bottom-level string from the {broken} data
    data = data.to_s if data.is_a?(Symbol)
    return check_match?(val, delim, data) && data if data.is_a?(String)
    data.is_a?(Hash) && data.find { |dkey, dvals|
      break dvals if check_match?(val, delim, dkey, dvals)

      nested_val = (
        case dvals
        when Hash
          dvals.find { |k,v|
            break v if check_match?(val, delim, k, v)
            matched_val = valstr_match(val, delim, v)
            break v if matched_val
          }
        when Array
          dvals.find { |dv| break dv if valstr_match(val, delim, dv) }
        when String # string to string -- Check if they match according to the delim
          check_match?(val, delim, dvals) && dvals
        else
          raise "Unhandled dvals class: #{dvals.class}"
        end
      )
      break nested_val if nested_val
    } || false
  rescue StandardError => e
    raise unless Rails.env.production?
  end

  def check_match?(val, delim, str, nested={})
    val = val.to_s.downcase
    str = str.to_s.downcase
    case delim
    when :contains then str.include?(val)
    when :not_contains then !str.include?(val)
    when :exact then val == str
    when :not, :not_exact then val != str
    when :regex
      ::Jarvis::Regex.match_data(str, val)&.tap { |md|
        @regex_match_data[:match_list] += md[:match_list]
        @regex_match_data[:named_captures].reverse_merge!(md[:named_captures])
      }.present?
    when :any
      Tokenizer.split(
        val,
        Tokenizer.wrap_regex("\""),
        Tokenizer.wrap_regex("'"),
        Tokenizer.wrap_regex("/"),
        Tokenizer.wrap_regex("(", ")"),
        unwrap: true,
      ).any? { |single_val|
        SearchBreakMatcher.new(single_val, { str => {} }, @parent || self).match?
      }
    else false
    end
  rescue StandardError => e
    raise unless Rails.env.production?
  end
end
