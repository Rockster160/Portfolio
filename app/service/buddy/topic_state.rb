module Buddy
  # What this thread is on RIGHT NOW, in a few sentences.
  #
  # History is not "the last X messages" and never was: Buddy::GPT::History
  # replays everything since `buddy_recap_at`, with MAX_MESSAGES = 100 only as a
  # backstop for when compaction has been failing silently. What decides when
  # that gets cut is Buddy::Compactor, and it fires on SIZE and ELAPSED TIME —
  # 20% of the available window, or 10% plus twenty quiet minutes. Both are
  # facts about the transcript's length. Neither is a fact about what the
  # conversation is about.
  #
  # So a long stretch on one subject gets compacted mid-thought, and three short
  # unrelated subjects share one undifferentiated block of history.
  #
  # This adds the missing axis without touching either. The verbatim messages
  # stay exactly as they were; a topic line rides alongside them saying what the
  # current stretch is about. When the conversation moves off it, the outgoing
  # topic is written down and the slot resets.
  #
  # ## What ends a topic
  #
  # Buddy::IdeaDwell#moved_on? already answers this, and its header explains why
  # it counts MESSAGES rather than minutes: "elapsed time says nothing about
  # whether a thought is finished" — somebody thinking something through at one
  # message an hour would have had every single message look like an ending.
  # This reuses that judgement rather than inventing a second one.
  #
  # It is deliberately NOT the only trigger. `moved_on?` needs a next subject to
  # notice, so somebody who says one heavy thing and closes the app would never
  # settle. Buddy::Compile's quiet timer covers that case, and whichever comes
  # first wins.
  module TopicState
    module_function

    # How much of the tail defines the current topic. Shorter than the compile
    # window on purpose: this is "what are we on", not "what happened today".
    WINDOW = 12

    # Below this there isn't a topic yet, there's an exchange.
    #
    # Six, the same number and the same reasoning as Buddy::IdeaDwell: three
    # full exchanges is a conversation, two messages is a mention. It also
    # bounds the cost — this runs behind every settle, so a lower bar would mean
    # a model call on someone saying "hey" and being answered.
    MIN_MESSAGES = 6

    # Messages OF THEIRS at the end of the window carrying nothing of the topic
    # before it counts as moved on.
    #
    # Buddy::IdeaDwell::MOVED_ON_TAIL is four, and its header calls that "two
    # full exchanges". That arithmetic assumed a thread made of two people
    # taking turns, and this one isn't: a travel alert, a "Who did: Puppy Down?"
    # form and a reminder firing all land in the window as messages, and three
    # of those in a row would satisfy a tail of four while nobody had said a
    # word. Counting only the half that is evidence makes two mean two again.
    MOVED_ON_TAIL = 2

    MODEL = "gpt-5.4-mini".freeze

    INSTRUCTIONS = <<~TXT.freeze
      Say what this conversation is currently about, in at most two sentences.

      Write it so somebody picking the thread up cold knows what is being
      discussed and where it has got to. Include what they are trying to decide
      or work out, if there is one.

      Not a summary of everything said. Not a list of topics. The CURRENT
      subject only, and only if there is one - if the last few messages are
      unrelated small talk with no thread running through them, reply with
      exactly: NONE

      Prose, no headers, no bullets, under 300 characters, no em dashes.
    TXT

    NONE = "NONE".freeze

    # The line that rides in the prompt, or nil when there's nothing worth
    # saying. Deliberately tiny — it's one or two sentences against a fixed
    # block of tens of thousands of tokens.
    def block_for(conversation)
      topic = conversation&.buddy_topic.to_s.strip
      return nil if topic.empty?

      <<~TXT
        ## What you're on right now

        #{topic}

        This is the thread you're currently in, not a record of it. If they've moved on, follow them - don't steer back to it.
      TXT
    end

    # Refresh the topic if it has changed, and hand the outgoing one to the
    # long-term store on the way past. Runs behind the turn, never in it.
    def settle!(conversation, over: false)
      return nil if conversation.nil? || conversation.user.nil?

      messages = window(conversation)
      return nil if messages.size < MIN_MESSAGES
      return nil unless over || changed?(conversation, messages)

      topic = distill(conversation, messages)
      # nil is the call having failed, and NONE is the model saying there's no
      # thread running through this. Only the second clears: a rate limit must
      # not cost a thread the topic it already had, because the next turn would
      # then read as though the subject had never been established.
      return nil if topic.nil?

      if topic == NONE
        clear!(conversation)
        return nil
      end

      conversation.update_columns(
        buddy_topic: topic.first(400), buddy_topic_at: Time.current, updated_at: Time.current,
      )
      topic
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "topic_state.settle",
        exception: e,
        user:      conversation&.user,
        extra:     { conversation_id: conversation&.id },
      )
      nil
    end

    def clear!(conversation)
      return if conversation.buddy_topic.blank?

      conversation.update_columns(buddy_topic: nil, buddy_topic_at: nil, updated_at: Time.current)
    end

    # Has the conversation moved off whatever the stored topic was?
    #
    # Same substring-over-significant-words test Buddy::IdeaDwell uses to decide
    # a stretch is over, pointed at the topic line rather than a held idea. No
    # stored topic means anything is a change.
    #
    # THEIR messages only, and that is the whole thing rather than a refinement.
    # A stored topic goes into the prompt for every turn, so the reply written
    # under it reaches for its vocabulary; reading that reply back as evidence
    # the subject hasn't changed is asking the topic whether the topic is still
    # current, and the answer is always yes. Prod conversation 21, 27 Aug: the
    # topic settled at 16:23 on a recurring-list problem and was still there at
    # 17:09 through a memory, two travel alerts, a chore form and a completely
    # unrelated question about product ideas - because Byte's own answer to that
    # question said "recurring", "list" and "already", so the tail matched and
    # nothing refreshed. Every reply after it was written under a description of
    # a conversation that had finished three quarters of an hour earlier.
    #
    # What this gate decides is whether to PAY for a re-distill, not whether the
    # topic is right, and the two failures are not the same size: a needless
    # refresh costs one cheap call and usually lands on the same topic again,
    # while a refusal leaves a wrong line in the prompt indefinitely. So it
    # leans toward re-reading.
    def changed?(conversation, messages)
      stored = conversation.buddy_topic.to_s
      return true if stored.strip.empty?

      terms = terms_for(stored)
      return true if terms.empty?

      tail = messages.select { |m| m.direction == "outbound" }.last(MOVED_ON_TAIL)
      return false if tail.size < MOVED_ON_TAIL

      tail.none? { |m|
        text = m.body.to_s.downcase
        terms.any? { |term| text.include?(term) }
      }
    end

    def terms_for(text)
      words = text.downcase.scan(/[a-z]+/)
      words.uniq.reject { |w|
        w.length < Buddy::IdeaDwell::MIN_WORD || Buddy::IdeaDwell::STOPWORDS.include?(w)
      }
    end

    def window(conversation)
      recent = conversation.byte_messages.order(created_at: :desc).limit(WINDOW * 3).to_a
      recent.reject { |m| Buddy::Compile.skip?(m) }.first(WINDOW).reverse
    end

    def distill(conversation, messages)
      result = Buddy::GPT::Client.new(model: MODEL, reasoning_effort: nil).stream(
        instructions: INSTRUCTIONS,
        input:        [{ role: :user, content: stretch(conversation, messages) }],
      )
      record_usage(result, conversation)
      return nil unless result[:ok]

      text = result[:text].to_s.strip
      text.delete("^A-Za-z").casecmp?(NONE) ? NONE : text.presence
    end

    def stretch(conversation, messages)
      name = conversation.buddy_name
      messages.map { |m|
        who = m.direction == "outbound" ? "Them" : name
        "#{who}: #{m.body.to_s.strip}"
      }.join("\n")
    end

    def record_usage(result, conversation)
      BuddyUsage.record!(
        result, user: conversation.user, kind: :compile, conversation: conversation
      )
    rescue StandardError => e
      Rails.logger.warn("[Buddy::TopicState] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
