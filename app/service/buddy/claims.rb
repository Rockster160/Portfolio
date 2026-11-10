# What a reply sounds like when it reports one particular tool, or one
# particular automation, as done.
#
# Buddy::GPT::Turn already catches a reply written in the voice of having acted
# on a turn where NOTHING ran. These are for the turn where something did, just
# not the thing the reply names: a list item added and a reminder "pulled down"
# with no cancel behind it, or a second nap skip answered off the receipt of
# the first. Knowing which thing is claimed is also what lets the corrective
# round name the call to make, rather than asking for "the tool" in general.
#
# Never shown to the model. They are read after a round, against what that
# turn actually called.
#
# An entry is added from real use - the Daily Audit proposes one for every
# reply it finds claiming something that never ran:
#
#   target   - a tool's name (Symbol), or an automation's name (String) for one
#              reached through run_jil_task
#   did      - what the claim says happened, read after "I didn't actually"
#   verbs    - past tenses that report it, opening the sentence or after "I"
#   about    - what has to be in the same sentence for those verbs to be about
#              this target
#   state    - optional: the same claim with nobody doing it ("quiet's on for
#              2 hours")
#   also     - other tools whose call backs the claim just as well
#   examples - the sentences that were seen, each with where it was seen. The
#              spec checks every one is caught.
module Buddy
  module Claims
    module_function

    Claim = Data.define(:target, :did, :pattern, :also, :examples)
    Hit = Data.define(:claim, :sentence)

    # The claim opens the sentence (after an emote), or follows "I" / "I've".
    OPENING = /(?:\A(?:\*[^*\n]+\*\s*)?|\bi(?:(?:'|’)ve)?\s+)(?:just\s+|already\s+|now\s+)?/i

    # A question is never a report of having done it ("Skipped that one
    # already?"), and nor is a claim negated before its verb ("Quiet isn't on
    # for long"). A negation AFTER the verb is part of the report: "pulled the
    # reminder down so it won't keep bugging you".
    QUESTION = /\?\s*\z/
    NEGATION = /\b(?:not|never|no\s+longer)\b|n(?:'|’)t\b|\bcannot\b/i

    def claim(target, did:, verbs:, about:, examples:, state: nil, also: [])
      done = /#{OPENING.source}(?:#{verbs.join("|")})\b(?=[^\n]*?(?:#{about.source}))/i
      pattern = state ? Regexp.union(done, state) : done
      Claim.new(target: target, did: did, pattern: pattern, also: also, examples: examples)
    end

    CLAIMS = [
      claim(
        "Whisper Skip Nap",
        did:      "skip Whisper's nap",
        verbs:    %w[skipped],
        about:    /\bnap\b|\bthat\s+one\b/,
        examples: {
          "Skipped that one too, so Whisper’s next nap is the one after this!"       => "prod 10321",
          "Skipped Whisper’s next nap. It’ll leave the one after that on the clock." => "eval prod 10321",
        },
      ),
      claim(
        "Whisper Quiet For",
        did:      "turn Whisper quiet on",
        verbs:    %w[turned switched put set started],
        about:    /\bquiet\b/,
        state:    /\bquiet(?:(?:'|’)s|\s+(?:mode\s+)?is)\s+(?:now\s+)?on\s+(?:for|until|till|til)\b/i,
        examples: {
          "*whisk* Whisper quiet is on for 2 hours." => "turn spec, silent turn",
          "Got it. I turned quiet mode on until 9."  => "the same claim, said by Buddy",
        },
      ),
      claim(
        "Tesla Navigate",
        did:      "send the car anywhere",
        verbs:    %w[sent pointed routed set],
        about:    /\bcar\b[^\n]*?\b(?:to|home|toward)\b/,
        examples: {
          "Sent the car to Costco."     => "eval, take me to Costco",
          "I set the car to head home." => "the same claim, with I",
        },
      ),
      claim(
        :cancel_reminder,
        did:      "remove that reminder",
        # "Pulled up" is a read: "I pulled up your reminders, there are three."
        verbs:    %w[pulled(?!\s+up\b) took deleted removed cancell?ed canceled cleared dropped],
        about:    /\b(?:reminders?|watch(?:es)?)\b/,
        examples: {
          "I pulled the flower bed reminder down so it won’t keep bugging you!" => "turn spec, pending cancel",
          "Cleared the vet reminder for you."                                   => "opening the sentence",
        },
      ),
      claim(
        :add_list_item,
        did:      "add that to the list",
        verbs:    %w[added put stuck popped slotted threw],
        about:    /\blists?\b|\bon\s+there\b|\bto\s+(?:\*\*|`)/,
        also:     %i[schedule_list_items edit_list_item],
        examples: {
          "Kk! I added those three to **Before Bed**." => "turn spec, silent turn",
          "Popped milk on the grocery list."           => "the same claim, opening the sentence",
        },
      ),
    ].freeze

    # Every claim in `body` that nothing in `ran` backs. `ran` holds the tools
    # this turn called without failing, as Symbols, and the automations it
    # named, as downcased Strings.
    def unbacked(body, ran:)
      sentences(body).flat_map { |sentence|
        next [] if sentence.match?(QUESTION)

        CLAIMS.filter_map { |claim|
          Hit.new(claim: claim, sentence: sentence) if reports?(claim, sentence) && !backed?(claim, ran)
        }
      }.uniq { |hit| hit.claim.target }
    end

    def reports?(claim, sentence)
      found = claim.pattern.match(sentence)
      found.present? && !sentence[0...found.end(0)].match?(NEGATION)
    end

    def backed?(claim, ran)
      return ran.include?(claim.target.downcase) if claim.target.is_a?(String)

      [claim.target, *claim.also].any? { |tool| ran.include?(tool) }
    end

    def sentences(body)
      body.to_s.split(/(?<=[.!?])\s+|\n+/).map(&:strip).compact_blank
    end
  end
end
