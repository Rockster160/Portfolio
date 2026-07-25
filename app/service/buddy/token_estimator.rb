module Buddy
  # Rough token estimate for a Buddy conversation, used only to decide
  # when to compact. We do NOT need exact tokenizer output - a coarse
  # char/4 heuristic on message bodies plus a fixed system-prompt
  # baseline is enough to hit 10% / 20% thresholds reliably.
  #
  # Post-compact the "history" is just the recap + messages after the
  # compact timestamp, so the same estimator naturally shrinks after a
  # rotation.
  module TokenEstimator
    module_function

    CHARS_PER_TOKEN     = 4
    PER_MESSAGE_OVERHEAD = 20   # role tags, framing tokens

    # Static system prompt cost. Rough breakdown at time of writing:
    #   time_preamble          ~120  tokens
    #   persona (byte.md)      ~600
    #   RULES_APPENDIX        ~1750
    #   tools appendix         ~450
    #   memories block         ~800
    #   context pointer       ~200
    #   Total fresh session   ~3900
    # First-turn adds tone_profile_buddy (~2200), so ~6100 fresh, ~3900
    # continuing. Use the continuing value as baseline; the delta only
    # matters on the very first turn and is not the threshold-crossing
    # case.
    SYSTEM_PROMPT_BASELINE = 3900

    def estimate_for(conversation)
      compact_at   = compact_timestamp(conversation)
      scope        = conversation.byte_messages
      scope        = scope.where("created_at > ?", compact_at) if compact_at
      body_tokens  = scope.pluck(:body).sum { |b| body_cost(b) }
      recap_tokens = recap_cost(conversation)
      SYSTEM_PROMPT_BASELINE + body_tokens + recap_tokens
    end

    def body_cost(body)
      return 0 if body.blank?
      (body.length / CHARS_PER_TOKEN) + PER_MESSAGE_OVERHEAD
    end

    def compact_timestamp(conversation)
      ts = conversation.metadata["buddy_recap_at"] if conversation.metadata.is_a?(Hash)
      return nil if ts.blank?

      Time.zone.parse(ts.to_s)
    rescue
      nil
    end

    def recap_cost(conversation)
      recap = conversation.metadata["buddy_recap"] if conversation.metadata.is_a?(Hash)
      body_cost(recap)
    end
  end
end
