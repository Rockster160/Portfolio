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
  # It is driven entirely by things that were going to happen anyway: the end of
  # a turn, and a compaction. There is nothing on a timer and nothing polling.
  #
  # Nothing about it is user-facing either. The note lands as a companion note
  # (marked as Buddy's own, never read back as their words) and the thread's
  # count goes up; there is no chip and no message, because a receipt for
  # bookkeeping on a conversation that has already moved on is an interruption.
  module IdeaDwell
    module_function

    # How far back to read. Long enough to watch a conversation settle onto one
    # subject, short enough that an idea touched once at the top of a long
    # thread drops back out before it starts collecting notes about nothing.
    WINDOW = 12

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
    # It has to leave room for the idea underneath it: MIN_MESSAGES + this must
    # stay under WINDOW, or the stretch scrolls out of the window in the same
    # breath that says it's over, and the note is never written.
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
      You keep one held idea up to date for someone's companion.

      You'll be given the idea as it stands - its seed, plus any notes already
      on it - and the stretch of conversation that was about it. Write the ONE
      note that stretch was worth: what they settled on, what they ruled out and
      why, a constraint or a correction that turned up, where the thinking got
      to.

      - Only what is NEW. Never restate the seed or anything already in a note.
      - Keep the reasons. "Ruled out a pressure mat" is half of it; "ruled out a
        pressure mat as overkill for the price" is the note.
      - A correction is the most valuable thing in a stretch. If they fixed
        something that was wrong, keep it and keep it plain.
      - Write it so either of you could pick this thought up cold in a month.
      - Prose, no headers, no bullets, under 600 characters, no em dashes.
      - It is YOUR note, not a quote of theirs. Don't write it as their words.
      - If the stretch genuinely added nothing that isn't already saved, reply
        with exactly: #{NOTHING}
    TXT

    # Write the note if this conversation has been building on a held idea and
    # that stretch has now ended. Returns the note, or nil when there was
    # nothing to settle. Never raises: an idea that doesn't get its note is a
    # thread that reads the way it did before any of this existed.
    #
    # `over` is the caller saying it already knows the stretch is finished, and
    # there is exactly one thing that knows that: a compaction, which is about
    # to push the whole exchange out of Buddy's context. After it there is no
    # turn left that could notice, so that's the last moment to write it down.
    # Left false, the only thing that ends a stretch is the conversation moving
    # off it.
    def settle!(conversation, over: false)
      user = conversation&.user
      return nil if user.nil?

      # Two settles of one stretch would write the same note twice, and a
      # compaction happens on the same turn whose end also settles. Whoever is
      # second has nothing to add, so it gives up rather than waits.
      attempt = ByteConversation.with_advisory_lock_result(
        "buddy_idea_settle:#{conversation.id}", timeout_seconds: 0
      ) { run_settle(user, conversation, over) }

      attempt.lock_was_acquired? ? attempt.result : nil
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "idea_dwell.settle",
        exception: e,
        user:      conversation&.user,
        extra:     { conversation_id: conversation&.id },
      )
      nil
    end

    def run_settle(user, conversation, over)
      messages = window(conversation)
      return nil if messages.size < MIN_MESSAGES

      idea = dwelt_on(user, messages)
      return nil if idea.nil?
      return nil unless over || moved_on?(idea, messages)

      write_note!(conversation, idea, messages)
    end

    # The one held idea this stretch has been building on without any of it
    # being written down, or nil. One at a time: a stretch that reads as being
    # about two ideas is a stretch that hasn't settled onto either.
    def dwelt_on(user, messages)
      texts = messages.map { |message| message.body.to_s.downcase }
      since = messages.first.created_at

      scored = held(user).filter_map { |idea| score(idea, texts, since) }
      scored.max_by { |row| [row[:messages], row[:terms]] }&.fetch(:idea)
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
      distinct = hit.flatten.uniq.size
      return nil if messages < MIN_MESSAGES || distinct < MIN_TERMS

      { idea: idea, messages: messages, terms: distinct }
    end

    # They're talking about something else now: the last couple of exchanges
    # have nothing of the idea left in them.
    def moved_on?(idea, messages)
      tail = messages.last(MOVED_ON_TAIL)
      return false if tail.size < MOVED_ON_TAIL

      terms = terms_for(idea)
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

    def write_note!(conversation, idea, messages)
      text = distill(conversation, idea, messages)
      return nil if text.blank? || text.delete("^A-Za-z").casecmp?(NOTHING)

      idea.notes.create!(body: text.first(BuddyIdeaNote::MAX_BODY), source: :companion)
    end

    # No reasoning: reading a transcript back is mechanical, and this runs
    # behind a conversation that has already ended.
    def distill(conversation, idea, messages)
      result = Buddy::GPT::Client.new(model: MODEL, reasoning_effort: nil).stream(
        instructions: INSTRUCTIONS,
        input:        [{ role: :user, content: brief(conversation, idea, messages) }],
      )
      record_usage(result, conversation)
      return nil unless result[:ok]

      result[:text].to_s.strip
    end

    def brief(conversation, idea, messages)
      <<~TXT
        THE IDEA AS IT STANDS:
        #{idea.transcript}

        THE CONVERSATION ABOUT IT:
        #{stretch(conversation, messages)}
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
