# The `:&` comparison: the same words in any order. Case, punctuation and
# spacing don't count, so "Burrito, chicken" and "chicken  burrito" are one
# thing while "chicken burrito bowl" is another. ApplicationRecord.words_sql is
# the same reduction in SQL; the two must agree.
module Tokenizing::Words
  PUNCTUATION = /[^[:alnum:][:space:]]+/

  def self.call(text)
    text.to_s.downcase.gsub(PUNCTUATION, "").split(/[[:space:]]+/).compact_blank.sort.join(" ")
  end
end
