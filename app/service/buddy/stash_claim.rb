module Buddy
  # A briefing that floats one of their stashed thoughts under a name they
  # never gave it.
  #
  # The seed carried one line - a storage idea for somebody else in the house,
  # sat there six weeks - and the briefing closed on "that front room drinks
  # thing for <them> is still sitting there if you want to come back to it
  # later". There is no front room and there are no drinks.
  #
  # The record is real and the sentence is about it: the trailing "for <them>"
  # comes straight off the line. Every word saying WHICH thought it is was
  # invented, which is the half that matters - a thought read back under a name
  # they never gave it is one they have to go and look up to find out they
  # never wrote it.
  #
  # Buddy::UnpromptedMemory is the guard next door and it correctly stands
  # down here: it cuts sentences naming memories the seed did NOT carry, and
  # this one the seed DID. Nothing anywhere checked that the words used to name
  # it were the words handed over.
  #
  # ## Why this section and not every section
  #
  # Everything else in a briefing is named by something that appears verbatim -
  # an agenda title, a chore, a figure, a weekday. A stashed thought is the one
  # fact that arrives as a free-form phrase somebody wrote themselves, which is
  # both why it can be paraphrased at all and why it must not be: the phrase is
  # the only handle they have on it.
  #
  # ## Why it takes a RATIO
  #
  # Reaching for the line and landing ONE of its words is the failure, and the
  # word it landed was the name on the end - which on its own convicts nothing.
  # Naming half of what makes the line its own is what separates the two real
  # shapes this takes from the invented one, measured against both: a float
  # that quotes the stash line back whole, and one reading "the biggest thing
  # on your mind is still the kennel auto-open idea".
  #
  # Same call as Buddy::JobHunt::SAME_ROLE, made for the same reason - a
  # headline abbreviates, so a partial name is the ordinary case and only a
  # mostly-absent one is a different subject.
  module StashClaim
    module_function

    # Half the words that are the thought's OWN - in it, and nowhere else in
    # the day. See `elsewhere`.
    NAMED_ENOUGH = 0.5

    # Short words carry no name. `Flourish.significant` already takes three
    # letters as its floor, and the fourth is what keeps a stray "bed" or "PC"
    # from standing in for the thought it was part of.
    MIN_LENGTH = 4

    def trim(body, facts)
      text = body.to_s
      return text if text.blank?

      # The thought, not the rendered line - see BriefingFacts.stash_floated.
      idea = Buddy::BriefingFacts.stash_floated(facts).first
      return text if idea.blank?

      said  = Buddy::Flourish.significant(idea[:idea]).to_set
      rest  = elsewhere(facts)
      marks = said.reject { |word| rest.include?(word) || word.length < MIN_LENGTH }
      return text if marks.empty?

      kept = []
      # The capture group keeps the separators, so the break that led INTO a
      # dropped sentence leaves with it - same split as Buddy::DayClaim.
      text.split(/((?<=[.!?])\s+)/).each { |part|
        if renamed?(part, said, marks, rest)
          Rails.logger.info("[Buddy::StashClaim] dropped a sentence renaming a stashed thought")
          kept.pop
        else
          kept << part
        end
      }

      out = kept.join.strip
      # Never hand back less than a sentence, same as the repairs either side.
      out.match?(/[a-z]/i) ? out : text
    rescue StandardError => e
      Rails.logger.warn("[Buddy::StashClaim] trim failed: #{e.class}: #{e.message}")
      body.to_s
    end

    # Every word the day carried OTHER than what is on their mind.
    #
    # Subtracted for the reason Buddy::UnpromptedMemory subtracts the facts: a
    # sentence sharing a word with something else on the day is about that, and
    # a guard that can reach an agenda item is a guard that eats real news.
    def elsewhere(facts)
      Buddy::Flourish.significant(facts.to_h.except(:stash).to_s).to_set
    end

    # Reaching for the line, and naming it as something else.
    #
    # A figure is a fact whatever the word overlap says, and a sentence
    # carrying one of the day's own words is about the day - both stay, in the
    # same direction Buddy::DayClaim takes.
    def renamed?(part, said, marks, rest)
      return false if part.match?(/\d/)

      words = Buddy::Flourish.significant(part).to_set
      return false unless words.intersect?(said)
      return false if words.intersect?(rest)

      marks.count { |word| words.include?(word) } < (marks.length * NAMED_ENOUGH)
    end
  end
end
