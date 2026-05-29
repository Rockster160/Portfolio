class Tokenizing::Matcher
  attr_accessor(
    :top_breaker,
    :top_data,
    :parent,
    :match_data,
  )

  def initialize(str_or_breaker, stream, parent=nil)
    @parent = parent
    @match_data = { match_list: [], named_captures: {} }
    @top_streams = (
      case stream
      when ::Hash then ::DotHash.every_stream(stream)
      else [::Array.wrap(stream)]
      end
    )
    @top_breaker = (
      case str_or_breaker
      when ::String then ::Tokenizing::Breaker.call(str_or_breaker)
      else str_or_breaker
      end
    )

    calculate_matches
  rescue StandardError => e
    Rails.logger.error("[Tokenizing::Matcher] #{e.class}: #{e.message} -  breaker=#{str_or_breaker.inspect}")
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

  def breaker_matches?(breaker, stream, delim=:exact)
    return matching_stream_values(breaker, delim, stream).compact.any? if breaker.is_a?(::String) || breaker.is_a?(::Symbol)

    ((breaker[:keys]&.flat_map { |val, broken|
      matching_streams = matching_stream_values(val, delim, stream)
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
      when ::Array then piece.filter_map { |nested_breaker|
        breaker_matches?(nested_breaker, stream, delim)
      }
      else
        raise "Unhandled piece class: #{piece.class}"
      end
    }&.compact || [])).compact.any?
  rescue StandardError => e
    Rails.logger.error("[Tokenizing::Matcher#breaker_matches?] #{e.class}: #{e.message}")
    raise unless Rails.env.production?
  end

  def matching_stream_values(val, delim, stream)
    stream.filter_map.with_index { |drop, idx|
      stream[(idx + 1)..] if delim_match?(val, delim, drop)
    }
  end

  def contain_or_regex?(drop, val)
    if val.match?(/^\s*\/.*?\/[img]*\s*$/)
      delim_match?(val, :regex, drop)
    else
      drop.to_s.downcase.include?(unwrap(val).to_s.downcase)
    end
  end

  def delim_match?(val, delim, drop)
    lower_val = unwrap(val).to_s.downcase
    lower_drop = drop.to_s.downcase
    case delim
    when :contains then contain_or_regex?(drop, val)
    when :not_contains then !contain_or_regex?(drop, val)
    when :exact then lower_val == lower_drop
    when :not, :not_exact then lower_val != lower_drop
    when :regex
      rx = val.to_s[/^\s*\/(.*?)\/[img]*\s*$/, 1] || val.to_s
      md = drop.to_s.strip.match(Regexp.new(rx, Regexp::IGNORECASE | Regexp::MULTILINE))
      md.present? && @match_data.tap {
        @match_data[:match_list] += md.to_a
        @match_data[:named_captures].reverse_merge!(md.named_captures.symbolize_keys)
      }
    when :any
      ::Tokenizer.split(val).any? { |single_val|
        unwrapped = ::Tokenizing::Breaker.unwrap(single_val)
        delim_match?(unwrapped, :contains, drop)
      }
    else false
    end
  rescue StandardError => e
    Rails.logger.error("[Tokenizing::Matcher#delim_match?] #{e.class}: #{e.message} -  val=#{val.inspect}")
    raise unless Rails.env.production?
  end

  private

  def unwrap(val)
    return val unless val.is_a?(::String)

    ::Tokenizing::Breaker.unwrap(val)
  end
end
