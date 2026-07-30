module Buddy
  # Rough token estimate of a Buddy conversation's HISTORY, used only to decide
  # when to compact. Exact tokenizer output isn't needed - a coarse char/4
  # heuristic on message bodies is enough to hit the thresholds reliably.
  #
  # Deliberately history-ONLY. The system prompt and tool schemas are a large
  # fixed cost (see FIXED_OVERHEAD) that compaction cannot reduce, so folding
  # them into the number being thresholded would mean every conversation looks
  # near-limit from its first message. History is the only thing compaction
  # shrinks, so history is what we measure. Buddy::Compactor compares this
  # against the window left over after the fixed cost.
  #
  # Post-compact the history is just the messages after `buddy_recap_at` plus
  # the recap, so the same estimator naturally shrinks after a rotation.
  module TokenEstimator
    module_function

    CHARS_PER_TOKEN      = 4
    PER_MESSAGE_OVERHEAD = 20   # role tags, framing tokens

    # Fixed per-turn cost of everything that is not conversation history.
    # Measured 2026-07-30 with the byte theme:
    #
    #   persona (byte.md)  ~1,260
    #   tone profile       ~2,880
    #   RULES_APPENDIX    ~10,650
    #   context guide      ~2,790
    #   framing + glance     ~120
    #   ---------------------------
    #   prompt total      ~17,700
    #   tool schemas      ~12,110   (35 proposal + 5 silent + get_context + read_prompt)
    #   ===========================
    #   TOTAL             ~29,810
    #
    # Re-measure if the rules, tone profile, or tool count change materially:
    #   Buddy::Personality.for(...).bytesize / 4
    #   JSON.generate(tool_schemas).bytesize / 4
    FIXED_OVERHEAD = 29_810

    def estimate_for(conversation)
      compact_at   = compact_timestamp(conversation)
      scope        = conversation.byte_messages
      scope        = scope.where("created_at > ?", compact_at) if compact_at
      body_tokens  = scope.pluck(:body).sum { |b| body_cost(b) }
      body_tokens + recap_cost(conversation)
    end

    def body_cost(body)
      return 0 if body.blank?

      (body.length / CHARS_PER_TOKEN) + PER_MESSAGE_OVERHEAD
    end

    def compact_timestamp(conversation)
      ts = conversation.metadata["buddy_recap_at"] if conversation.metadata.is_a?(Hash)
      return nil if ts.blank?

      Time.zone.parse(ts.to_s)
    rescue StandardError
      nil
    end

    def recap_cost(conversation)
      recap = conversation.metadata["buddy_recap"] if conversation.metadata.is_a?(Hash)
      body_cost(recap)
    end
  end
end
