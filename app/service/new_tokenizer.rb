# tz = Tokenizer.new(str)
# tz.untokenize!(str)

class NewTokenizer
  WRAP_PAIRS = {
    "(" => ")",
    "[" => "]",
    "{" => "}",
    "\"" => "\"",
    "'" => "'",
    "/" => "/"
  }

  attr_accessor :text, :tokenized_text, :tokens

  def self.split(text, untokenize: true, unwrap: false)
    tz = new(text)
    tz.tokenized_text.split(" ").map { |str|
      untokenize ? tz.untokenize(str, unwrap: unwrap) : str
    }
  end

  def initialize(text, extra_pairs={}, only: nil)
    @pairs = only.nil? ? WRAP_PAIRS.merge(extra_pairs) : only
    @tokens = {}
    @token_count = 0

    @text = tokenize_quotes(text)
    @tokenized_text, _cursor = tokenize
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

  private

  def tokenize_quotes(str)
    tokenized = str.to_s.dup
    loop do
      first_idx = find_index(tokenized, "\"")
      break if first_idx.nil?

      next_idx = find_index(tokenized, "\"", after: first_idx)
      break if next_idx.nil?

      quoted = tokenized[first_idx..next_idx]
      token = generate_token
      tokenized[first_idx..next_idx] = token
      @tokens[token] = quoted
    end
    tokenized
  end

  def find_index(str, char, after: -1)
    str.enum_for(:scan, /[#{Regexp.escape(char)}]/).find { |_m|
      idx = Regexp.last_match.begin(0)
      next unless idx > after

      escapes = str[...idx][/\\*$/].length
      return idx if escapes.even?
    }
  end

  def tokenize(until_char=nil, idx=0, nest=0)
    h = "#{"> "*nest}[#{[rand(16).to_s(16), rand(16).to_s(16)].join.upcase}]"
    buffer = ""

    # logit "#{h}:#{idx}:tokenize:#{until_char}"
    loop do
      if idx >= text.length
        return unless until_char.nil? # Unmatched char, exit without replacing
        break
      end

      top = nest == 0
      char = text[idx]
      next_escaped = char == "\\" && idx < text.length && text[...idx+1][/\\*$/].length.odd?

      if next_escaped
        # Remove the escape and add the next character instead
        buffer << "\\" + text[idx+1]
        idx += 1 # Extra increment to skip next character
      elsif char == until_char
        # Found closing char, time to exit
        # logit "#{h}:#{idx}:close:#{char}"
        buffer << char
        break
      elsif @pairs.key?(char)
        next_idx = find_index(text, @pairs[char], after: idx)
        if next_idx.nil?
          buffer << char
        else
          # logit "#{h}:#{idx}:open:#{char}"
          wrapped, next_idx = tokenize(@pairs[char], idx+1, nest+1)

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

  def generate_token
    @token_count += 1
    "||TOKEN#{@token_count}||"
  end
end
