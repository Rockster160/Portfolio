module Buddy
  # One thing said twice in one message.
  #
  # Two shapes of it, and they arrive by completely different roads:
  #
  #   Prod 5296, 3 Sep. One model call, no tools, no retry — Suki answered a
  #   question about reminders and then answered it again in the next paragraph,
  #   reworded. Nothing structural to point at; it is a generation artefact, and
  #   the only place it can be caught is on the way out.
  #
  #   Prod 5401, 4 Sep. "Whisper nap sound." sitting over "Playing the nap sound
  #   on Whisper" — a note the person wrote, and the task's own account of what
  #   it did. Both true, both about to be read as one message repeating itself.
  #
  # Deliberately NOT phrase matching. It compares the SIGNIFICANT WORDS of two
  # paragraphs and asks whether the shorter one is almost entirely contained in
  # the longer, which is what "you already said that" is in data. Unbounded
  # phrasing regexes are the trap this codebase has been caught by before (see
  # the silent-turn guard); a set comparison has no phrasing in it at all.
  #
  # The bar is high on purpose. Deleting a paragraph somebody meant to send is a
  # far worse failure than leaving a repetitive one in, so prose needs SIX
  # significant words before it is eligible at all, and then 80% of them have to
  # already be up there.
  module Restatement
    module_function

    # Below this a paragraph is a fragment, and fragments look alike for reasons
    # that have nothing to do with repetition: "Do Dishes at 3 PM" and "Do Dishes
    # at 8 PM" share every word that survives normalizing.
    MIN_WORDS = 6
    COVERAGE  = 0.8

    # Structure rather than prose — a bullet list, a heading, a table row, a
    # fenced block. Two of these being similar is a formatting fact, not a
    # companion saying the same thing twice.
    STRUCTURAL_RX = /\A\s*(?:[-*+>#|]|\d+[.)]|```)/

    # Words that carry no subject. Kept short: this only has to stop grammar
    # from counting as agreement, and every word taken out is one that can no
    # longer distinguish two paragraphs from each other.
    FILLER = <<~WORDS.split.to_set.freeze
      and are but can could for from had has have its just like more not now one
      out say she still than that the their them then there these they this too
      was were what when will with would you your
    WORDS

    # Does `second` say what `first` already said?
    #
    # `min_words` is loosened by the one caller that has STRUCTURE on its side:
    # a header line over a step's own answer is scaffolding whose entire job is
    # "something happened", so two words is enough to know the answer has taken
    # its place.
    def restates?(first, second, min_words: MIN_WORDS)
      a = significant(first)
      b = significant(second)
      return false if a.length < min_words || b.length < min_words

      shorter, longer = [a, b].sort_by(&:length)
      ((shorter & longer).length.to_f / shorter.length) >= COVERAGE
    end

    # Drop any paragraph that restates one already above it. The FIRST wording
    # survives: a restatement is the second attempt at a sentence that already
    # landed, and in prod 5296 the opening paragraph was also the fuller one.
    def collapse(text)
      body = text.to_s
      return body if body.blank?

      paras = body.split(/\n{2,}/)
      return body if paras.length < 2

      kept = []
      paras.each { |para|
        if para.match?(STRUCTURAL_RX) || kept.none? { |seen| restates?(seen, para) }
          kept << para
          next
        end

        Rails.logger.warn(
          "[Buddy::Restatement] dropped a restated paragraph: #{para.strip.truncate(140).inspect}",
        )
      }
      kept.join("\n\n")
    end

    def significant(text)
      text.to_s.downcase.scan(/[a-z]{3,}/).map(&:singularize).uniq.reject { |w| FILLER.include?(w) }
    end
  end
end
