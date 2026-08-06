module Buddy
  # Writes down the thinking that happened out loud about a held idea, once the
  # conversation has finished doing it.
  #
  # `elaborate_idea` shipped with an instruction to reach for it whenever
  # somebody builds on something Buddy is already holding, and it went unused. A
  # 22-minute design conversation about a stashed kennel idea ended with that
  # idea byte-for-byte as it was seeded — the sensor options weighed, the two
  # ruled out and why, the correction that the door was still only planned, all
  # of it surviving nowhere but the chat log. Every turn in the stretch was a
  # question or an opinion, which is exactly how the Rules define the pure
  # conversation that correctly takes no tools, so the specific instruction lost
  # to a general rule that is right nearly every other time it applies.
  #
  # Asking the turn to write the note is also asking it at the wrong moment: mid
  # stretch there is no "where it landed" yet, and a note per message would be
  # twelve near-identical notes on one thought. So this waits for the stretch to
  # END, reads the whole thing back, and writes the single note it was worth.
  #
  # A stretch ends when the conversation MOVES OFF it, and nothing here consults
  # a clock to decide that. An earlier cut called it over after six quiet
  # minutes, which is only ever true of somebody sitting down to it in one go:
  # a person thinking something through at one message an hour between other
  # things would have had every single message look like the end of the
  # conversation, and collected a note for each one — the exact churn this
  # exists to avoid. Elapsed time says nothing about whether a thought is
  # finished. What the next messages are ABOUT says everything.
  #
  # A stretch is also not assumed to be about ONE thing. People tangent: the
  # kennel reminds them of the greenhouse, they weave between the two, and both
  # get further along. So every idea the stretch was building on gets settled,
  # each with its own note; a tangent onto another held idea is not an ending,
  # because they haven't finished, they've switched tracks; and no idea's note
  # is written without the others being named, so what belongs to the greenhouse
  # doesn't quietly end up filed under the kennel.
  #
  # It is driven entirely by things that were going to happen anyway: the end of
  # a turn, and a compaction. There is nothing on a timer and nothing polling.
  #
  # Nothing about it is user-facing either. The note lands as a companion note
  # (marked as Buddy's own, never read back as their words) and the thread's
  # count goes up; there is no chip and no message, because a receipt for
  # bookkeeping on a conversation that has already moved on is an interruption.
  module IdeaDwell
    module_function

    # How far back to read. Ten exchanges is a session: long enough to watch a
    # conversation settle, short enough that an idea touched once at the top of
    # a long thread drops back out before it collects notes about nothing.
    #
    # It has to be big enough to hold a stretch two subjects are SHARING, plus
    # the tail that ends it. At 12 it wasn't: two tangented ideas needing
    # MIN_MESSAGES each, behind a MOVED_ON_TAIL, is 16 messages, so the second
    # idea could only ever clear the bar by borrowing the first one's messages.
    # Tangenting would have looked exactly like never tangenting.
    WINDOW = 20

    # Messages in that window that have to touch the idea. Six is three full
    # exchanges spent on one thought, which is a conversation. Two is a mention,
    # and a mention is what the seed already covers.
    MIN_MESSAGES = 6

    # Distinct words of the idea's OWN that the window has to hit. One shared
    # word is a coincidence — "open" matches the garage and "sensor" matches
    # every device in the house — and it's the second and third that make the
    # idea the subject rather than a passing overlap.
    MIN_TERMS = 3

    # Below this a word is doing grammar, not naming anything.
    MIN_WORD = 4

    # What ends a stretch: this many messages at the end of the window with
    # nothing of the idea in them. Four is two full exchanges, so a single
    # unrelated question in the middle of thinking something through doesn't cut
    # the stretch in half — and it's counted in messages rather than minutes, so
    # two exchanges is two exchanges whether they took a minute or a fortnight.
    #
    # It has to leave room for the ideas underneath it: (MIN_MESSAGES × the
    # subjects a stretch can share) + this must stay under WINDOW, or the
    # stretch scrolls out of the window in the same breath that says it's over,
    # and the note is never written.
    MOVED_ON_TAIL = 4

    # Words that carry no topic. Matching on these is how "close the garage"
    # ends up looking like a conversation about the kennel. Only 4+ letters,
    # since anything shorter is already excluded.
    STOPWORDS = Set.new(%w[
      about above after again also another anything around because been before
      being both came come could does doing done down each else even ever every
      from gets getting give goes going gone good have having here idea ideas
      into just keep kind know like little look made make many maybe might more
      most much must need needs never next note notes once only other over part
      plan quite rather really right said same seem seems should since some
      something sort still stuff such sure take than that their them then there
      these they thing things think this those though thought through time took
      used using very want wants well went were what when where which while
      with would your
    ]).freeze

    # Message kinds that aren't somebody talking: the hidden prompt behind a
    # quick action, the chip that renders one, a tool's own receipt, a watch
    # firing on its own. Counting those would let a doorbell notification vote
    # on what the conversation is about.
    SKIP_KINDS = %w[action_chip buddy_activity buddy_trigger].freeze

    # Cheapest thing that can read a transcript and write three sentences off
    # it, same as compaction. Distilling is not the work Buddy is good at, it's
    # the work Buddy needs done quietly.
    MODEL = "gpt-5.4-mini".freeze

    # What the model says instead of a note when the stretch added nothing that
    # isn't already on the thread. An escape hatch the heuristic needs: six
    # messages can touch an idea without any of them taking it anywhere.
    NOTHING = "NOTHING".freeze

    INSTRUCTIONS = <<~TXT.freeze
      You keep ONE held idea up to date for someone's companion.

      You'll be given that idea as it stands - its seed, plus any notes already
      on it - and a stretch of conversation. Write the one note that stretch was
      worth: what they settled on, what they ruled out and why, a constraint or
      a correction that turned up, where the thinking got to.

      - Only what is NEW. Never restate the seed or anything already in a note.
      - Keep the reasons. "Ruled out a pressure mat" is half of it; "ruled out a
        pressure mat as overkill for the price" is the note.
      - A correction is the most valuable thing in a stretch. If they fixed
        something that was wrong, keep it and keep it plain.
      - The conversation may weave between more than one thing they're holding,
        and any others get named for you. Write about YOURS only. Something
        settled about a different one is being written down separately and does
        not belong in your note, even where the two were being compared - keep
        the part that changes your idea, leave the rest.
      - Write it so either of you could pick this thought up cold in a month.
      - Prose, no headers, no bullets, under 600 characters, no em dashes.
      - It is YOUR note, not a quote of theirs. Don't write it as their words.
      - If the stretch genuinely added nothing to YOUR idea that isn't already
        saved, reply with exactly: #{NOTHING}
    TXT

    # Write a note on every held idea this conversation has been building on and
    # has now moved off. Returns those notes, oldest idea first, empty when
    # there was nothing to settle. Never raises: an idea that doesn't get its
    # note is a thread that reads the way it did before any of this existed.
    #
    # `over` is the caller saying it already knows the stretch is finished, and
    # there is exactly one thing that knows that: a compaction, which is about
    # to push the whole exchange out of Buddy's context. After it there is no
    # turn left that could notice, so that's the last moment to write it down.
    # Left false, the only thing that ends a stretch is the conversation moving
    # off it.
    def settle!(conversation, over: false)
      user = conversation&.user
      return [] if user.nil?

      # Two settles of one stretch would write the same notes twice, and a
      # compaction happens on the same turn whose end also settles. Whoever is
      # second has nothing to add, so it gives up rather than waits.
      attempt = ByteConversation.with_advisory_lock_result(
        "buddy_idea_settle:#{conversation.id}", timeout_seconds: 0
      ) { run_settle(user, conversation, over) }

      attempt.lock_was_acquired? ? attempt.result : []
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "idea_dwell.settle",
        exception: e,
        user:      conversation&.user,
        extra:     { conversation_id: conversation&.id },
      )
      []
    end

    def run_settle(user, conversation, over)
      messages = window(conversation)
      return [] if messages.size < MIN_MESSAGES

      ideas = dwelt_on(user, messages)
      return [] if ideas.empty?
      return [] unless over || moved_on?(ideas, messages)

      ideas.filter_map { |idea| write_note!(conversation, idea, ideas, messages) }
    end

    # Every held idea this stretch has been building on without any of it being
    # written down. Usually one; deliberately not ONLY one.
    #
    # Half an hour of thinking out loud is not half an hour on a single subject.
    # People tangent — the kennel reminds them of the greenhouse, they weave
    # between the two, and both get further along. Settling only the one with
    # the most hits would drop the other's thinking on the floor, which is the
    # exact failure this whole thing exists to fix, just narrower.
    def dwelt_on(user, messages)
      texts = messages.map { |message| message.body.to_s.downcase }
      since = messages.first.created_at

      scored = held(user).filter_map { |idea| score(idea, texts, since) }
      own_subject(scored).pluck(:idea)
    end

    # Which of several co-scoring ideas are really separate subjects.
    #
    # Held ideas share vocabulary all the time — "kennel auto-open with a door
    # sensor" and "upgrade the garage door sensor" have `door`, `sensor` and
    # `open` in common, so a conversation about one clears the bar for the
    # other and would collect a note about something never discussed. A wrong
    # note on a thread is worse than a missing one: it's read back months later
    # as a thing that was decided.
    #
    # So when more than one scores, each has to carry MIN_TERMS of its OWN that
    # no other candidate matched. Kennel keeps `kennel`, `whisper`, `dispenser`;
    # the garage keeps nothing but the shared three and drops out, while a
    # genuine tangent to the greenhouse keeps plenty and stays.
    def own_subject(scored)
      return scored if scored.size < 2

      alone = scored.select { |row|
        shared = (scored - [row]).flat_map { |other| other[:hits] }
        exclusive(row[:hits], shared).size >= MIN_TERMS
      }
      # Everything overlapping everything is one subject matching several ways,
      # not several subjects. Keep the strongest rather than nothing.
      alone.presence || [scored.max_by { |row| [row[:messages], row[:hits].size] }]
    end

    # Compared as substrings, the way every other match here is. Term equality
    # would count "close" and "closed" as a word each idea owns, which is two
    # ideas' worth of evidence out of one word in one message.
    def exclusive(hits, shared)
      hits.reject { |term|
        shared.any? { |other| term.include?(other) || other.include?(term) }
      }
    end

    # The same pool the prompt's "Things you're holding" list draws from, so a
    # note can only ever land on an idea the conversation could have been about.
    def held(user)
      return [] unless user.respond_to?(:buddy_ideas)

      scope = user.buddy_ideas.live.includes(:notes).order(created_at: :asc)
      scope.limit(Buddy::Personality::OPEN_LOOP_LIMIT).to_a
    end

    # How much of this window the idea actually accounts for. Nil unless it
    # clears both bars and nothing has landed on the thread since the window
    # opened — a note written two messages ago means the turn already did this,
    # which is the better outcome and the one that wins.
    def score(idea, texts, since)
      last_note = idea.notes.map(&:created_at).max
      return nil if last_note && last_note >= since

      terms = terms_for(idea)
      return nil if terms.size < MIN_TERMS

      hit      = texts.map { |text| terms.select { |term| text.include?(term) } }
      messages = hit.count(&:any?)
      hits     = hit.flatten.uniq
      return nil if messages < MIN_MESSAGES || hits.size < MIN_TERMS

      { idea: idea, messages: messages, hits: hits }
    end

    # They're talking about something else now: the last couple of exchanges
    # have nothing of ANY of these ideas left in them.
    #
    # Asked one idea at a time this reads a tangent as an ending, and two ideas
    # being woven together would take turns declaring each other over: four
    # messages on the greenhouse settles the kennel, four back on the kennel
    # settles the greenhouse, and a conversation that was going somewhere gets
    # chopped into notes about where it had got to halfway. Bouncing between two
    # things they're holding is one session of thinking, and it ends when they
    # move off BOTH.
    def moved_on?(ideas, messages)
      tail = messages.last(MOVED_ON_TAIL)
      return false if tail.size < MOVED_ON_TAIL

      terms = ideas.flat_map { |idea| terms_for(idea) }.uniq
      tail.none? { |message|
        text = message.body.to_s.downcase
        terms.any? { |term| text.include?(term) }
      }
    end

    # The words of an idea worth matching on: its own vocabulary, minus
    # everything that belongs to English rather than to this thought. Matched as
    # substrings so "sensor" catches "sensors" and "open" catches "opening"
    # without any of the machinery a stemmer would cost.
    def terms_for(idea)
      words = "#{idea.summary} #{idea.body}".downcase.scan(/[a-z]+/)
      words.uniq.reject { |word| word.length < MIN_WORD || STOPWORDS.include?(word) }
    end

    # The recent back-and-forth, oldest first. Both directions, because Buddy
    # talking at length about an idea says as much about what the conversation
    # is about as the person doing it.
    def window(conversation)
      recent = conversation.byte_messages.order(created_at: :desc).limit(WINDOW * 3).to_a
      recent.reject { |message| skip?(message) }.first(WINDOW).reverse
    end

    def skip?(message)
      meta = message.metadata.is_a?(Hash) ? message.metadata : {}
      return true if meta["hidden"]
      return true if meta["source"] == "watch"
      return true if SKIP_KINDS.include?(meta["kind"].to_s)

      message.body.to_s.strip.empty?
    end

    def write_note!(conversation, idea, ideas, messages)
      text = distill(conversation, idea, ideas, messages)
      return nil if text.blank? || text.delete("^A-Za-z").casecmp?(NOTHING)

      idea.notes.create!(body: text.first(BuddyIdeaNote::MAX_BODY), source: :companion)
    end

    # One call per idea, over the SAME transcript. Splitting the messages up by
    # which idea they mention would be cheaper and would also throw away the
    # half of a tangent that's worth keeping — "same sensor as the kennel, but
    # for the greenhouse" only means anything with both sides of it present. The
    # model gets the whole conversation and is told which thread it's writing.
    #
    # No reasoning: reading a transcript back is mechanical, and this runs behind
    # a conversation that has already moved on.
    def distill(conversation, idea, ideas, messages)
      result = Buddy::GPT::Client.new(model: MODEL, reasoning_effort: nil).stream(
        instructions: INSTRUCTIONS,
        input:        [{ role: :user, content: brief(conversation, idea, ideas, messages) }],
      )
      record_usage(result, conversation)
      return nil unless result[:ok]

      result[:text].to_s.strip
    end

    def brief(conversation, idea, ideas, messages)
      <<~TXT
        THE IDEA YOU ARE WRITING ABOUT:
        #{idea.transcript}
        #{alongside(idea, ideas)}
        THE CONVERSATION:
        #{stretch(conversation, messages)}
      TXT
    end

    # Names the other threads the same stretch touched, so their content can be
    # recognised and left where it belongs. Without this the model has one idea
    # and a transcript half about something else, and the obliging thing to do
    # with the rest is fold it in.
    def alongside(idea, ideas)
      others = ideas - [idea]
      return "" if others.empty?

      labels = others.map { |other| "- #{other.summary.presence || other.body.to_s.truncate(80)}" }
      <<~TXT

        THEY ALSO TANGENTED ONTO THESE, WHICH ARE NOT YOURS TO WRITE:
        #{labels.join("\n")}
      TXT
    end

    def stretch(conversation, messages)
      name = conversation.buddy_name
      messages.map { |message|
        who = message.direction == "outbound" ? "Them" : name
        "#{who}: #{message.body.to_s.strip}"
      }.join("\n")
    end

    # Its own usage kind. A settle bills like a compaction and is invisible like
    # one, but folding the two together would make either number unreadable the
    # first time one of them looked wrong.
    def record_usage(result, conversation)
      BuddyUsage.record!(
        result,
        user:         conversation.user,
        kind:         :idea_note,
        conversation: conversation,
      )
    rescue StandardError => e
      Rails.logger.warn("[Buddy::IdeaDwell] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
