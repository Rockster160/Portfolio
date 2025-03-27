class Tokenizer
  # PRIORITY_PAIRS = { ... } - Add double quotes here, and run this instead of `tokenize_quotes`
  TOKEN_REGEX = /__TOKEN\d+__/
  WRAP_PAIRS = {
    "(" => ")",
    "[" => "]",
    "{" => "}",
    "\"" => "\"",
    "'" => "'",
    "/" => "/"
  }

  attr_accessor :raw, :text, :tokenized_text, :tokens

  def self.split(text, untokenize: true, unwrap: false)
    tz = new(text)
    tz.tokenized_text.split(" ").map { |str|
      untokenize ? tz.untokenize(str, unwrap: unwrap) : str
    }
  end

  def self.find_unescaped_index(str, char, after: -1)
    str.enum_for(:scan, /[#{Regexp.escape(char)}]/m).find { |_m|
      idx = Regexp.last_match.begin(0)
      next unless idx > after

      escapes = str[...idx][/\\*\z/].length
      return idx if escapes.even?
    }
  end

  def self.find_unescaped_pair(str, char)
    first_idx = find_unescaped_index(str, char)
    return if first_idx.nil?

    next_idx = find_unescaped_index(str, char, after: first_idx)
    return if next_idx.nil?

    [first_idx, next_idx]
  end

  def self.tokenize(str, extra_pairs={}, only: nil, &block)
    tz = new(str, extra_pairs, only: only)
    changed = block.call(tz.tokenized_text)
    tz.tokenized_text = changed if changed.is_a?(String)
    tz.untokenize
  end

  def initialize(text, extra_pairs={}, only: nil)
    @pairs = only.nil? ? WRAP_PAIRS.merge(extra_pairs) : only
    @tokens = {}
    @token_count = 0

    @raw = text.to_s # .to_s dups
    @text = @pairs["\""] == "\"" ? tokenize_quotes(text) : text
    @tokenized_text, _cursor = tokenize(@text)
  end

  def untokenize(str=nil, levels=nil, unwrap: false, &block)
    untokenized = (str || @tokenized_text).dup
    i = 0
    loop do
      break if levels.present? && i >= levels
      break if @tokens.none? { |token, txt|
        untokenized.gsub!(token) {
          val = unwrap ? txt[1..-2] : txt
          block ? block.call(val) : val
        }
      }
      i += 1
    end
    untokenized
  end

  def tokenize_regex(regex, replace=nil, &block)
    @tokenized_text.gsub!(regex) { |match|
      token = generate_token
      value = replace || Regexp.last_match[1] || match
      @tokens[token] = block_given? ? block.call(value) : value
      token
    }
  end

  def tokenize(str, until_char=nil, idx=0, nest=0, pairs: @pairs)
    h = "#{"> "*nest}[#{[rand(16).to_s(16), rand(16).to_s(16)].join.upcase}]"
    buffer = ""

    # logit "#{h}:#{idx}:tokenize:#{until_char}"
    loop do
      if idx >= str.length
        return unless until_char.nil? # Unmatched char, exit without replacing
        break
      end

      top = nest == 0
      char = str[idx]
      next_escaped = char == "\\" && idx < str.length && str[...idx+1][/\\*$/].length.odd?

      if next_escaped
        # Remove the escape and add the next character instead
        buffer << "\\" + str[idx+1]
        idx += 1 # Extra increment to skip next character
      elsif char == until_char
        # Found closing char, time to exit
        # logit "#{h}:#{idx}:close:#{char}"
        buffer << char
        break
      elsif pairs.key?(char)
        next_idx = ::Tokenizer.find_unescaped_index(str, pairs[char], after: idx)
        if next_idx.nil?
          buffer << char
        else
          # logit "#{h}:#{idx}:open:#{char}"
          wrapped, next_idx = tokenize(str, pairs[char], idx+1, nest+1)

          if wrapped.nil?
            # logit "#{h}:#{idx}:\e[31m No close '#{char}'"
            # Pair did not close, add the char and move on
            buffer << char
            # return unless until_char.nil?
          else
            idx = next_idx
            token = generate_token
            buffer << token
            @tokens[token] = "#{char}#{wrapped}"
            # logit "#{h}:#{idx}:\e[32mAdded \e[0m'#{@tokens[token]}'"
          end
        end
      else
        buffer << char
      end

      idx += 1
    end
    # logit "#{h}:#{idx}:buffer:\e[0m'#{buffer}'"

    [buffer, idx]
  end

  private

  def tokenize_quotes(str)
    tokenized = str.to_s.dup
    loop do
      first_idx, next_idx = ::Tokenizer.find_unescaped_pair(tokenized, "\"")
      break if first_idx.nil? || next_idx.nil?

      quoted = tokenized[first_idx..next_idx]
      token = generate_token
      tokenized[first_idx..next_idx] = token
      @tokens[token] = quoted
    end
    tokenized
  end

  def generate_token(full_str=@raw)
    loop do
      @token_count += 1
      token = "__TOKEN#{@token_count}__"
      break token unless full_str.include?(token)
    end
  end
end
