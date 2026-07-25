module Buddy
  # Decides when a Buddy conversation is getting long enough to compact,
  # and orchestrates the compaction. Compaction = ask Mac to generate a
  # short recap of the current session via a cheap Haiku call, store the
  # recap on the conversation, clear the Mac's buddy_session_id so the
  # next turn starts fresh. The recap rides in the next turn's system
  # prompt so Buddy doesn't lose long-arc context.
  #
  # Thresholds (per Rocco):
  #   >= 20% context (40k tokens) -> force compact
  #   >= 10% context (20k tokens) AND >= 20 min since last reply -> soft
  #     compact (safe: user is coming back after a gap, no live thread
  #     to break mid-turn)
  #   else -> don't compact
  module Compactor
    module_function

    CTX_WINDOW              = 200_000
    HARD_PCT                = 0.20
    SOFT_PCT                = 0.10
    SOFT_GAP_MINUTES        = 20

    def should_compact?(conversation, now: Time.current)
      tokens = TokenEstimator.estimate_for(conversation)
      return :hard if tokens >= HARD_PCT * CTX_WINDOW
      return nil   if tokens <  SOFT_PCT * CTX_WINDOW

      last_at = conversation.last_message_at
      return nil if last_at.blank?
      return :soft if (now - last_at) >= SOFT_GAP_MINUTES.minutes

      nil
    end

    # Blocking: HTTP to Mac to run the Haiku summary and clear the
    # session id, then store the recap on the conversation. Returns
    # the recap text on success, nil on any failure (compaction is a
    # nice-to-have; a failed compact must NEVER block the actual turn).
    def compact!(conversation)
      response = ByteLocal.compact_buddy_session(conversation_id: conversation.id)
      return nil unless response.is_a?(Hash)

      recap = response["summary"].to_s.strip
      return nil if recap.empty?

      merged = (conversation.metadata || {}).merge(
        "buddy_recap"    => recap,
        # iso8601(6) so the timestamp survives fractional-second
        # comparison against message.created_at when a message row was
        # written moments before the compact call.
        "buddy_recap_at" => Time.current.iso8601(6),
      )
      conversation.update!(metadata: merged)
      recap
    rescue => e
      Rails.logger.warn("[Buddy::Compactor] compact failed conv=#{conversation.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
