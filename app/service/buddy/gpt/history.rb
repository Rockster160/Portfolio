module Buddy
  module GPT
    # Rebuilds the Responses-API `input` array from ByteMessage rows.
    #
    # We deliberately do NOT use `previous_response_id`: Rails already owns
    # every message, so rebuilding each turn means no conversation state lives
    # outside our database, compaction is a truncation rather than a protocol
    # dance, and a turn is reproducible from the rows alone.
    #
    # Direction maps to role: `outbound` is the person (including the hidden
    # seed prompts Buddy::TodayBriefing and Buddy::Stash inject), `inbound` is
    # Buddy.
    module History
      module_function

      # Safety cap. Compaction should keep threads far below this; the cap only
      # matters if compaction has been failing silently.
      MAX_MESSAGES = 100

      # Inbound kinds that represent something Buddy actually SAID. Receipt
      # chips (`buddy_activity`), action-request cards, and system/meta replies
      # are excluded: their outcomes already show up in the live context, and
      # replaying them as assistant turns teaches Buddy to narrate receipts.
      PROSE_KINDS = ["buddy", "buddy_reply"].freeze

      # Cross-household bridged messages (Buddy::CompanionRelay#bridge!). These
      # are a third voice in the thread: text from the partner's companion, or a
      # copy of what we passed along to them. They render as inbound bubbles the
      # person can see and will refer back to ("what did he say?"), so leaving
      # them out made Buddy blind to half of a relay conversation — a bare
      # "tacos" with no visible question to attach it to.
      #
      # They ride as assistant turns (there's no role for a third party) with a
      # bracketed attribution prefix. Buddy::Personality's relay section tells the
      # model those brackets are system framing so it doesn't write them itself.
      RELAY_KIND = "buddy_relay".freeze

      def build(conversation, upto:)
        rows = scope(conversation, upto)
        rows.filter_map { |msg| item_for(msg) }
      end

      def scope(conversation, upto)
        scope = conversation.byte_messages.chronological
        scope = scope.where(byte_messages: { created_at: ..upto.created_at }) if upto
        compact_at = compact_timestamp(conversation)
        scope = scope.where(byte_messages: { created_at: compact_at... }) if compact_at
        # Take the most recent MAX_MESSAGES, then restore chronological order.
        scope.to_a.last(MAX_MESSAGES)
      end

      def item_for(message)
        body = message.body.to_s.strip
        return nil if body.empty?

        if message.direction == "outbound"
          { role: :user, content: body }
        elsif prose_reply?(message)
          { role: :assistant, content: body }
        elsif relay?(message)
          { role: :assistant, content: relay_content(message, body) }
        end
      end

      # Buddy's own replies only, and only once settled. A `streaming` or
      # `failed` row is a half-written or abandoned turn; replaying it as
      # history would have Buddy continue from a sentence it never finished.
      def prose_reply?(message)
        return false unless message.state == "delivered"

        PROSE_KINDS.include?(kind_of(message))
      end

      def relay?(message)
        kind_of(message) == RELAY_KIND
      end

      # `source` distinguishes the two halves bridge! writes: "relay" is the copy
      # in the RECIPIENT's thread (incoming from the partner), "relay_copy" is the
      # record in the SENDER's thread of what went out.
      def relay_content(message, body)
        meta = message.metadata.is_a?(Hash) ? message.metadata : {}
        peer = meta.dig("relay_peer", "name").presence || "their companion"

        if meta["source"].to_s == "relay_copy"
          "[you passed this along to #{peer}] #{body}"
        else
          "[relayed to you from #{peer}] #{body}"
        end
      end

      def kind_of(message)
        message.metadata.is_a?(Hash) ? message.metadata["kind"].to_s : ""
      end

      # Same source of truth Buddy::TokenEstimator uses, so "what we send" and
      # "how big we think it is" can't disagree about where history starts.
      def compact_timestamp(conversation)
        ts = conversation.metadata["buddy_recap_at"] if conversation.metadata.is_a?(Hash)
        return nil if ts.blank?

        Time.zone.parse(ts.to_s)
      rescue StandardError
        nil
      end
    end
  end
end
