module Buddy
  # Decides when a Buddy conversation is getting long enough to compact, and
  # runs the compaction.
  #
  # Compaction = summarize the stretch since the last compact into a few
  # sentences focused on relational continuity, store it on the conversation,
  # and stamp `buddy_recap_at`. Buddy::GPT::History truncates at that stamp, so
  # the next turn starts from the recap instead of replaying everything, and
  # Buddy::Personality#recap_block feeds the recap back into the prompt.
  #
  # This used to be an HTTP call to the Mac, which ran `claude --resume` against
  # a Haiku model and cleared its session id. There is no session to clear now —
  # history is ours — so it's a local model call over the same rows the turn
  # itself would have sent.
  #
  # Thresholds are percentages of the window left for CONVERSATION after the
  # fixed prompt + tool-schema cost, not of the raw window:
  #   >= 20% of available -> force compact
  #   >= 10% of available AND >= 20 min since last reply -> soft compact
  #     (safe: the user is coming back after a gap, so there's no live thread
  #     to break mid-turn)
  #   else -> don't compact
  module Compactor
    module_function

    # GPT-5.4-mini's context window. Twice the 200k this assumed when Buddy ran
    # on Claude, so in absolute terms these thresholds are far more generous
    # than they were — a hard compact lands around 75k tokens of history.
    CTX_WINDOW = 400_000

    # What's actually left for history. The fixed overhead is ~18% of the window
    # on its own, so thresholding against CTX_WINDOW directly would have every
    # conversation looking near-limit from its very first message — and
    # compacting can't reclaim any of it anyway.
    AVAILABLE_WINDOW = CTX_WINDOW - Buddy::TokenEstimator::FIXED_OVERHEAD

    HARD_PCT         = 0.20
    SOFT_PCT         = 0.10
    SOFT_GAP_MINUTES = 20

    # Cheapest thing that can write three decent sentences. Summarizing is not
    # the work Buddy is good at, it's the work Buddy needs done quietly.
    MODEL = "gpt-5.4-mini".freeze

    INSTRUCTIONS = <<~TXT.freeze
      You are summarizing a conversation between a person and their companion
      (Buddy) so the companion can pick the thread back up later without
      feeling amnesiac.

      Write 3-5 short sentences from Buddy's perspective. Focus on what matters
      for continuing the relationship: what the person is going through, what
      they've said they care about, ongoing threads, the emotional arc,
      unfinished asks. Do NOT list every topic; distill.

      No headers, no bullets, no meta-framing like "here is a summary" - just
      the prose. Under 500 characters. No em dashes.
    TXT

    def should_compact?(conversation, now: Time.current)
      tokens = TokenEstimator.estimate_for(conversation)
      return :hard if tokens >= HARD_PCT * AVAILABLE_WINDOW
      return nil   if tokens <  SOFT_PCT * AVAILABLE_WINDOW

      last_at = conversation.last_message_at
      return nil if last_at.blank?
      return :soft if (now - last_at) >= SOFT_GAP_MINUTES.minutes

      nil
    end

    # Returns the recap text on success, nil on any failure. Compaction is a
    # nice-to-have: a failed compact must NEVER block the actual turn, it just
    # means the next turn carries more history than we'd like.
    def compact!(conversation)
      history = Buddy::GPT::History.build(conversation, upto: nil)
      return nil if history.length < 2

      result = Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: INSTRUCTIONS,
        input:        history + [{ role: :user, content: "Summarize our conversation so far." }],
      )
      # Compaction has no reply message to hang off, so it records with a nil
      # byte_message_id under its own kind. Its whole job is to make later turns
      # cheaper, so being able to see what it costs is the point.
      record_usage(result, conversation)
      return nil unless result[:ok]

      recap = result[:text].to_s.strip
      return nil if recap.empty?

      store_recap(conversation, recap)
      recap
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "compactor.compact",
        exception: e,
        user:      conversation.user,
        extra:     { conversation_id: conversation.id },
      )
      nil
    end

    def record_usage(result, conversation)
      BuddyUsage.record!(
        result,
        user:         conversation.user,
        kind:         :compaction,
        conversation: conversation,
      )
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Compactor] usage record failed: #{e.class}: #{e.message}")
    end

    def store_recap(conversation, recap)
      merged = (conversation.metadata || {}).merge(
        "buddy_recap"    => recap,
        # iso8601(6) so the timestamp survives fractional-second comparison
        # against message.created_at when a row was written moments before.
        "buddy_recap_at" => Time.current.iso8601(6),
      )
      conversation.update!(metadata: merged)
    end
  end
end
