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
    # An `input_image`, once OpenAI tiles it. Rough, but bodies alone would say
    # a photo costs nothing — the one case where char/4 is not merely coarse but
    # blind. Only the NEWEST message counts: History sends an image's pixels once
    # on the turn it arrives, and every replay after that is just its filename.
    IMAGE_TOKENS = 1_100

    # Fixed per-turn cost of everything that is not conversation history.
    # Measured 2026-08-02 with the byte theme:
    #
    #   persona (byte.md)  ~1,875
    #   tone profile       ~3,050
    #   RULES_APPENDIX    ~12,395
    #   context guide      ~3,160
    #   framing + glance     ~410
    #   ---------------------------
    #   prompt total      ~20,890
    #   tool schemas      ~14,985
    #   ===========================
    #   TOTAL             ~35,875
    #
    # The schema half had drifted ~2,000 high: it was last written down as an
    # estimate rather than a measurement, and the number carried forward through
    # several rounds of tool edits. Reading high only makes compaction fire
    # early, which is why nothing surfaced it.
    #
    # Re-measure if the rules, tone profile, or tool count change materially —
    # against a user who has every feature, since the schemas are gated:
    #   Buddy::Personality.for(user, conversation: c).bytesize / 4
    #   JSON.generate(Buddy::Tools.function_schemas(user: user)).bytesize / 4
    FIXED_OVERHEAD = 35_875

    def estimate_for(conversation)
      compact_at   = compact_timestamp(conversation)
      scope        = conversation.byte_messages
      scope        = scope.where("created_at > ?", compact_at) if compact_at
      body_tokens  = scope.pluck(:body).sum { |b| body_cost(b) }
      body_tokens + image_cost(scope) + recap_cost(conversation)
    end

    def image_cost(scope)
      newest = scope.order(created_at: :desc).limit(1)
      count  = ActiveStorage::Attachment.where(
        record_type: "ByteMessage", name: :files, record_id: newest.select(:id),
      ).count

      count * IMAGE_TOKENS
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
