module SearchParser
  module_function

  def call(str)
    str = str.dup
    tr = Tokenizer.new(str)
    tr.tokenize!(str, /\\\"/)
    tr.tokenize!(str, /".*?"/)

    pieces = str.split(" ").map { |piece| tr.untokenize!(piece) }
    pieces.each_with_object({}) do |piece, obj|
      if piece.match?(/[\w"!]:[\w"]/)
        key, val = piece.split(":")
        obj[key.to_sym] ||= []
        obj[key.to_sym] << (val.match?(/^".*?"$/) ? val[1..-2] : val)
      else
        obj[:words] ||= []
        obj[:words] << (piece.match?(/^".*?"$/) ? piece[1..-2] : piece)
      end
    end
  end
end

# SearchParser.call("name:thing has:\"bigger string\" search each word !:bad")
# {
#   "name":  [
#     "thing"
#   ],
#   "has":   [
#     "bigger string"
#   ],
#   "words": [
#     "search",
#     "each",
#     "word"
#   ],
#   "!":     [
#     "bad"
#   ]
# }
