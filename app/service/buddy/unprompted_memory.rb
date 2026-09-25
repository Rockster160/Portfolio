module Buddy
  # A briefing naming back one of the heavy things they're carrying.
  #
  # A morning briefing can close with "And I'm holding that <X> note for you
  # too, so you don't have to keep it in your head". The record is real - theirs,
  # in their own words - but the seed carried no section about it at all. It
  # came from `situation_block`, which rides in every prompt.
  #
  # That block's instruction is bolded and could not be plainer:
  #
  #   **Do not name it back at them unprompted.** Bringing it up is theirs to
  #   do. Saying the hard thing out loud to prove you remembered can land as
  #   picking at a bruise, and they cannot un-hear it.
  #
  # This is that failure in the exact form the paragraph describes: announcing
  # that it is being held, to prove it is being held, when nothing was asked.
  #
  # ## Why a briefing is the one place this is checkable
  #
  # Everywhere else, naming a carried thing can be right - they raised it, and
  # following their lead is the whole rule. A briefing has no "they": the seed
  # is the input and the seed decides the subject, so anything about a carried
  # memory arrived unprompted by definition.
  #
  # ## Why the facts are subtracted
  #
  # A memory about somebody's surgery and an agenda item for that surgery share
  # their words. If the seed carried it, the briefing is ALLOWED to say it -
  # that is the seed doing its job. So only the words that are in the memory and
  # NOT in the facts can convict a sentence, which makes "the seed decides the
  # subject" the literal test rather than a paraphrase of one.
  module UnpromptedMemory
    module_function

    def trim(body, memories, facts)
      text = body.to_s
      return text if text.blank?

      rows = Array(memories)
      # Two pools, two bars, and two different things being counted: a carried
      # memory convicts on one word out of all of them together, a preference on
      # two words out of ONE note. See `names?` and `loose_word_sets`.
      light, heavy = rows.partition { |memory| memory.respond_to?(:kind_preference?) && memory.kind_preference? }
      private_words = distinctive(heavy, facts)
      loose_sets    = loose_word_sets(light, facts)
      return text if private_words.empty? && loose_sets.empty?

      kept = []
      # Same split and the same separator handling as Buddy::DayClaim and
      # `without_empty_chore_note`: the break that led INTO a dropped sentence
      # leaves with it.
      text.split(/((?<=[.!?])\s+)/).each { |part|
        if names?(part, private_words, at_least: 1) || loose_sets.any? { |words| names?(part, words, at_least: 2) }
          Rails.logger.info("[Buddy::UnpromptedMemory] dropped a sentence naming a prompt-resident memory")
          kept.pop
        else
          kept << part
        end
      }

      out = kept.join.strip
      # Never hand back less than a sentence, same as the repairs either side.
      out.match?(/[a-z]/i) ? out : text
    rescue StandardError => e
      Rails.logger.warn("[Buddy::UnpromptedMemory] trim failed: #{e.class}: #{e.message}")
      body.to_s
    end

    # The words that belong to a carried memory and to nothing the seed said.
    #
    # NOT logged, and never returned anywhere they could be written down: these
    # are the contents of the heaviest things somebody has said, and this module
    # exists to keep them out of a message.
    def distinctive(memories, facts)
      said = Buddy::Flourish.significant(facts.to_s).to_set
      Array(memories).flat_map { |memory|
        Buddy::Flourish.significant(memory.content.to_s)
      }.uniq.reject { |word| said.include?(word) || word.length < 4 }
    end

    # Each preference's own words, ONE LIST PER NOTE rather than all of them
    # poured into a single bag.
    #
    # The bar was two words and the bag was every preference at once, so two
    # words out of two DIFFERENT notes convicted a sentence - and against
    # twenty-odd live preferences almost any warm sentence clears that. A
    # briefing lost the only line on it that way: the float sentence said a
    # two-week-old thought was still `sitting` there and invited her to get
    # `back` to it, and those two words came from two unrelated notes, one about
    # a pile of thoughts and one about being distracted.
    #
    # `names?`'s own comment has always described a per-note rule - "the
    # preferences worth guarding are whole phrases and land several of their
    # words in one sentence". This is the code catching up with it.
    #
    # A word that two different notes BOTH use is dropped as well, on the same
    # ground the facts are subtracted on: vocabulary two notes share is ordinary
    # vocabulary, and belongs to neither of them.
    def loose_word_sets(memories, facts)
      lists  = Array(memories).map { |memory| distinctive([memory], facts) }
      shared = lists.flatten.tally.filter_map { |word, count| word if count > 1 }.to_set
      lists.map { |words| words.reject { |word| shared.include?(word) } }.reject(&:empty?)
    end

    # One distinctive word is enough for a carried memory, and that is
    # deliberate. A briefing has no reason to reach for a word that is in one of
    # those and in nothing it was handed; the cost of dropping a sentence is a
    # shorter briefing, and the cost of keeping one is the thing the bolded rule
    # is about.
    #
    # A PREFERENCE takes two, because its vocabulary is the briefing's
    # vocabulary. A note reading "my list means the Ongoing TO DO list"
    # contributes `list`, and at a one-word bar that convicts every sentence
    # about a list - while the preferences worth guarding are whole phrases and
    # land several of their words in one sentence. Two words of the SAME note,
    # which is what `loose_word_sets` exists to ask.
    def names?(part, private_words, at_least: 1)
      return false if private_words.empty?

      words = Buddy::Flourish.significant(part).to_set
      private_words.count { |word| words.include?(word) } >= at_least
    end
  end
end
