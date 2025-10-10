class Tokenizing::Breaker
  WORD_RX = /[a-z0-9_]+/i
  NON_WORD_RX = /[^\sa-z0-9_]+/i
  BREAKER_RX = /(?:#{WORD_RX}|#{NON_WORD_RX})/i

  def self.breakdown(str)
    tz = Tokenizer.new(str)
    text = tz.tokenized_text
    pieces = text.scan(BREAKER_RX)
    pieces.map { |piece|
      next piece unless piece.match?(Tokenizer::TOKEN_REGEX)

      full_piece = tz.untokenize(piece)
      wrap_start, content, _wrap_last = full_piece.scan(/\A(.)(.*)(.)\z/m).flatten

      case wrap_start
      when /[({\[]/ then breakdown(content)
      # when /["']/ then content -- We want the strings so we know what to parse
      when /\// then full_piece
      else full_piece
      end
    }
  end
end
