class SearchBreakMatcher
  attr_accessor(
    :top_breaker,
    :top_data,
    :parent,
    :regex_match_data,
  )

  DELIMITERS = {
    contains:     ":",
    exact:        "::",
    not:          "!",
    not_contains: ":!",
    not_exact:    "::!",
    regex:        "~",
    any:          ["ANY", "ANY:"],
  }
  # These could be actual/custom Objects that return the expected data based on calls.
  # That would solve the issues of having conflicting keys.
  # We could also store the "top" level data as the object with the current dug match for filtering.
  # Object could have a match? method as well as a `dig` method to return the lowest level of match
  # https://github.com/mrkamel/search_cop
  # Possible gem that implements this and might be useable
  # "-" should work as not:
  #  * "Rowling -Potter" == `Rowling not(Potter)`
  #  * "Rowling -(Harry Potter)" == `Rowling not(Harry) not(Potter)`
  #  * "Rowling -'Harry Potter'" == `Rowling not('Harry Potter')`

  # str   ="event:datam:fuzzy_val"
  # data  =["event", "data", "custom", "nested_key", "fuzzy_val thing"]
  # parent=<SearchBreakMatcher>
  def initialize(str_or_breaker, stream, parent=nil)
    @parent = parent
    @regex_match_data = { match_list: [], named_captures: {} }
    @top_streams = (
      case stream
      when ::Hash then ::DotHash.every_stream(stream)
      else [::Array.wrap(stream)]
      end
    )
    @top_breaker = (
      case str_or_breaker
      when ::String then ::SearchBreaker.call(str_or_breaker, DELIMITERS)
      else str_or_breaker # Should be a Breaker hash
      end
    )

    calculate_matches
  rescue StandardError => e
    # binding.pry
    raise unless Rails.env.production?
  end

  def calculate_matches
    return @matched = false if @top_streams.blank?

    @matched = @top_streams.any? { |stream| breaker_matches?(@top_breaker, stream) }
  end

  def match?
    return @matched if defined?(@matched)

    calculate_matches
  end

  # {data} -- ...key: key: key: "string"
  # data = { event: { data: { custom: { nested_key: "fuzzy_val thing" } } } }
  # {breaker} -- broken.keys & [:keys, :vals]
  #   keys: {{broken}, {broken}, ...}
  # {broken} -- broken.keys & [:contains, ...]
  #   {delim}: [{piece}, {piece}]
  # {delim} -- contains|exact|delims
  # {piece} -- [String, {breaker}]

  def breaker_matches?(breaker, stream, delim=:exact)
    if breaker.is_a?(::String) || breaker.is_a?(::Symbol)
      return matching_stream_values(breaker, delim, stream).compact.any?
    end

    ((breaker[:keys]&.flat_map { |val, broken| # val="event" && broken[:contains] = [{piece}]
      matching_streams = matching_stream_values(val, delim, stream) # This should iterate through every stream value and return the list that follows AFTER the matching key
      matching_streams.flat_map { |downstream|
        next true if broken.blank?
        broken.flat_map { |down_delim, breakers|
          breakers.filter_map { |down_breaker|
            breaker_matches?(down_breaker, downstream, down_delim)
          }
        }
      }
    }&.compact || []) + (breaker[:vals]&.flat_map { |delim, piece|
      case piece
      when ::Array then piece.filter_map { |nested_breaker| breaker_matches?(nested_breaker, stream, delim) }
      # when ::String, ::Symbol then valstr_matches(piece, delim, stream)
      else
        # binding.pry
        raise "Unhandled piece class: #{piece.class}"
      end
    }&.compact || [])).compact.any?
  rescue StandardError => e
    # binding.pry
    raise unless Rails.env.production?
  end

  def matching_stream_values(val, delim, stream)
    stream.filter_map.with_index { |drop, idx|
      # TODO: Handle not_<delim>
      stream[(idx+1)..] if delim_match?(val, delim, drop)
      # nil means no match, but an empty array means it successfully matched, but there is no lower data, so any further checks will fail
    }
  end

  def delim_match?(val, delim, drop)
    val = val.to_s.downcase
    drop = drop.to_s.downcase
    case delim
    when :contains then drop.include?(val)
    when :not_contains then !drop.include?(val)
    when :exact then val == drop
    when :not, :not_exact then val != drop
    when :regex
      ::Jarvis::Regex.match_data(drop, val)&.tap { |md|
        @regex_match_data[:match_list] += md[:match_list]
        @regex_match_data[:named_captures].reverse_merge!(md[:named_captures])
      }.present?
    when :any
      ::Tokenizer.split(
        val,
        ::Tokenizer.wrap_regex("\""),
        ::Tokenizer.wrap_regex("'"),
        ::Tokenizer.wrap_regex("/"),
        ::Tokenizer.wrap_regex("(", ")"),
        unwrap: true,
      ).any? { |single_val|
        delim_match?(single_val, :contains, drop) # Should this default to contains or exact?
      }
    else false
    end
  rescue StandardError => e
    # binding.pry
    raise unless Rails.env.production?
  end
end
