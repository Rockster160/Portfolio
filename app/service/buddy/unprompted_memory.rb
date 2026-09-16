module Buddy
  # A briefing naming back one of the heavy things they're carrying.
  #
  # Prod 6243, 15 Sep. Moss closed Chelsea's morning briefing with "And I'm
  # holding that <X> note for you too, so you don't have to keep it in your
  # head". The record was real - hers, in her own words, from 10 Sep - and the
  # seed (6242) carried `due, jobs, name, week, stash, today, alpine, waiting,
  # weather` and no section about it at all. It came from `situation_block`,
  # which rides in every prompt.
  #
  # That block's instruction is bolded and could not be plainer:
  #
  #   **Do not name it back at them unprompted.** Bringing it up is theirs to
  #   do. Saying the hard thing out loud to prove you remembered can land as
  #   picking at a bruise, and they cannot un-hear it.
  #
  # This is that failure in the exact form the paragraph describes: announcing
  # that it is being held, to prove it is being held. Chelsea had said nothing.
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

      private_words = distinctive(memories, facts)
      return text if private_words.empty?

      kept = []
      # Same split and the same separator handling as Buddy::DayClaim and
      # `without_empty_chore_note`: the break that led INTO a dropped sentence
      # leaves with it.
      text.split(/((?<=[.!?])\s+)/).each { |part|
        if names_one?(part, private_words)
          Rails.logger.info("[Buddy::UnpromptedMemory] dropped a sentence naming a carried memory")
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

    # One distinctive word is enough, and that is deliberate. A briefing has no
    # reason to reach for a word that is in a carried memory and in nothing it
    # was handed; the cost of dropping a sentence is a shorter briefing, and the
    # cost of keeping one is the thing the bolded rule is about.
    def names_one?(part, private_words)
      words = Buddy::Flourish.significant(part).to_set
      private_words.any? { |word| words.include?(word) }
    end
  end
end
