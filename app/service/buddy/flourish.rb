module Buddy
  # A trailing "..., which is <something charming>" that says nothing.
  #
  # Rocco, 2026-09-05: "'{statement} which is {unnecessary description}' is back
  # and annoying." Three in the seven days before that, all on briefings, all
  # the same shape:
  #
  #   prod 5445  Not much on deck from here, which is either peaceful or
  #              suspiciously peaceful.
  #   prod 5248  Then tonight's got meatballs & power Mac, which is a nice
  #              little anchor.
  #   prod 5017  Otherwise it looks nice and open for you, which is a small
  #              mercy!
  #
  # THIS IS THE FOURTH ATTEMPT AND THE FIRST ONE THAT ISN'T PROSE. TONE banned
  # the shape and the model moved the same empty flourish mid-sentence; the ban
  # was replaced by the FUNCTION plus a subtraction test ("cut it, and if they
  # still know everything they knew before, it was decoration"), and the shape
  # came back in its original form anyway. A rule that has lost three times is
  # not going to be won by wording it a fourth way, and the model is told
  # nothing about this - which is also why it can't relocate.
  #
  # The subtraction test is what's mechanised, for the one shape where "says as
  # much" is computable: a trailing `which` clause carrying no fact is a clause
  # that can go without losing anything. A clause with a figure in it, or a word
  # out of the day it is attached to, is doing work and stays.
  module Flourish
    module_function

    # Comma required. A restrictive "which" with no comma is part of the
    # sentence's own grammar ("the one which fits"), and the padding shape is
    # always the non-restrictive one. Bounded to the end of its sentence, so it
    # can never eat the clause after it.
    TRAILING_RX = /,\s+which\b[^,.!?;:]{0,120}(?=[.!?]|\z)/i

    # Longer than this and it is carrying something, whatever the word overlap
    # says. All three of the real ones ran to seven words or fewer.
    MAX_WORDS = 12

    FILLER = <<~WORDS.split.to_set.freeze
      all and are bit but can for from good got has have his her its just
      like little lot more much new nice not one only our out own real she
      some the their them they this those very was way well were what which
      with you your
    WORDS

    # `facts` is whatever the day was built from - a Hash, a String, anything
    # with words in it. Only its WORDS matter, so it is read as text rather
    # than walked, and a shape change upstream can't break this.
    def trim(body, facts)
      text = body.to_s
      return text if text.blank?

      keep = significant(facts.to_s)
      out  = text.gsub(TRAILING_RX) { |clause|
        next clause if carries_something?(clause, keep)

        Rails.logger.info("[Buddy::Flourish] dropped #{clause.strip.inspect}")
        ""
      }
      # Never hand back less than a sentence. A body that was nothing but the
      # flourish is a generation this has no opinion about, and punctuation on
      # its own is not a reply.
      out.match?(/[a-z]/i) ? out.strip : text
    end

    # Counted RAW, not significant: a fifteen-word clause is carrying something
    # whatever survives the filler list, and it is the length that says so.
    def carries_something?(clause, keep)
      return true if clause.split.length > MAX_WORDS
      return true if clause.match?(/\d/)

      significant(clause).intersect?(keep)
    end

    def significant(text)
      text.to_s.downcase.scan(/[a-z]{3,}/).map(&:singularize).uniq.reject { |w| FILLER.include?(w) }
    end
  end
end
