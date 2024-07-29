class SearchBreakMatcher
  include Memoizeable
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
  # These could be actual/custom Objects that return the expected data based on calls.
  # That would solve the issues of having conflicting keys.

  def initialize(str, data, parent=nil)
    @parent = parent
    @regex_match_data = { match_list: [], named_captures: {} }
    @top_breaker = SearchBreaker.call(str, DELIMITERS)
    @top_data = data

    match?
  rescue StandardError => e
    # binding.pry
    raise unless Rails.env.production?
  end

  def match?
    return @matched if defined?(@matched)
    return @matched = false if !@top_data.is_a?(::Hash) || @top_data.keys.none?
    raise "Only 1 top level key allowed" unless @top_data.keys.one?

    @matched = breaker_matches(@top_breaker, @top_data).any?
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
    if (breaker.is_a?(::String) || breaker.is_a?(::Symbol)) && passed_delim.present?
      return valstr_matches(breaker, passed_delim, data)
    end

    (breaker[:keys]&.filter_map { |val, broken| # val="event" && broken[:contains] = [{piece}]
      if passed_delim.present?
        data = valstr_matches(val, passed_delim, data)
        next false if !data
      end

      top_match = broken.empty? && valstr_matches(val, :contains, data)
      next top_match if top_match

      broken.filter_map { |delim, piece|
        case piece
        when ::Array then piece.filter_map { |nested_breaker| breaker_matches(nested_breaker, data, delim) }
        else valstr_matches(val, delim, data)
        end
      }
    }&.flatten || []) + (breaker[:vals]&.filter_map { |delim, piece|
      case piece
      when ::Array then piece.filter_map { |nested_breaker| breaker_matches(nested_breaker, data, delim) }
      when ::String, ::Symbol then valstr_matches(piece, delim, data)
      else
        raise "Unhandled piece class: #{piece.class}"
      end
    }&.flatten || [])
  rescue StandardError => e
    # binding.pry
    raise unless Rails.env.production?
  end

  def valstr_matches(val, delim, data) # val is a bottom-level string from the {broken} data
    if delim.to_s.starts_with?("not_")
      invert_delim = delim.to_s[4..].to_sym
      # Do something for `not` by itself?
      return if valstr_matches(val, invert_delim, data).present?
    end
    return data.filter_map { |d| valstr_matches(val, delim, d) }.flatten if data.is_a?(::Array)
    data = data.to_s if data.is_a?(::Symbol)
    return check_match?(val, delim, data) && data if data.is_a?(::String)
    data.is_a?(::Hash) && data.filter_map { |dkey, dvals|
      next dvals if check_match?(val, delim, dkey, dvals)

      nested_val = (
        case dvals
        when ::Hash
          dvals.filter_map { |k,v|
            next {k => v} if check_match?(val, delim, k, v)
            matched_val = valstr_matches(val, delim, v)
            next v if matched_val
          }
        when ::Array
          dvals.filter_map { |dv| next dv if valstr_matches(val, delim, dv) }
        when ::String # string to string -- Check if they match according to the delim
          check_match?(val, delim, dvals) && dvals
        else
          raise "Unhandled dvals class: #{dvals.class}"
        end
      )
      next nested_val if nested_val
    }.presence
  rescue StandardError => e
    # binding.pry
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
    end.tap { |b|
      puts "\e[3#{b ? 2 : 1}m#{val}[#{delim}]#{str}\e[0m"
    }
  rescue StandardError => e
    # binding.pry
    raise unless Rails.env.production?
  end
end
