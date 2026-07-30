module Buddy
  # A correction replaces the thing it corrects.
  #
  # "Add trail mix to Shopping" lands a row; "that was supposed to be under
  # Costco" lands another one. Left alone the thread now shows the same item
  # twice with one of them wrong — and on a level-2 row that's worse than
  # cosmetic, because both rows point at the SAME record: unchecking the stale
  # one to tidy up deletes what the corrected one just filed properly.
  #
  # Identity is the tool's own `merge_key`, which already means "the same thing,
  # asked for again" — it's what collapses duplicates inside a single turn. A
  # tool that declares none gets a fresh random key per call, so it never
  # matches and never replaces anything. That's the right default: retiring
  # someone's pending ask is only safe where the tool has said what makes two
  # calls the same thing.
  module Supersede
    module_function

    PROPOSALS = "buddy_proposals".freeze
    STATUS    = "superseded".freeze

    # A checklist stays tappable for days, but a correction lands within a few
    # exchanges. Bounded so a long thread doesn't rescan its whole history.
    LOOKBACK = 25

    # What a row can be retired FROM. `pending` is an ask nobody answered;
    # `executed` is a level-2 row whose record the new one has just rewritten.
    # Everything else (failed, cancelled, undone, already superseded) is history
    # and stays exactly as it is.
    REPLACEABLE = %w[pending executed].freeze

    # Retire whatever `action` replaces. `keys` are the merge_keys it just
    # posted; anything earlier in the same conversation carrying one of them is
    # done with.
    def replace!(action:, keys:)
      wanted = Array(keys).map(&:to_s).compact_blank.to_set
      return if wanted.empty? || action.byte_conversation_id.blank?

      rescued = recent(action).flat_map { |old| retire(old, wanted) }
      return if rescued.empty?

      # A queue rescued off something we just retired belongs behind whatever
      # replaced it, rather than nowhere.
      input = action.tool_input.is_a?(Hash) ? action.tool_input : {}
      action.update!(tool_input: input.merge("deferred" => Array(input["deferred"]) + rescued))
    rescue StandardError => e
      Buddy::Errors.report(section: "supersede.replace", exception: e, user: action&.user)
      nil
    end

    class << self
      private

      def recent(action)
        ByteAction
          .where(byte_conversation_id: action.byte_conversation_id, tool_name: [PROPOSALS, Buddy::FormAction::TOOL_NAME])
          .where.not(id: action.id)
          .order(created_at: :desc)
          .limit(LOOKBACK)
          .to_a
      end

      # Returns whatever queue was stranded by retiring this one.
      def retire(action, wanted)
        rescued = []
        touched = false

        action.with_lock do
          action.reload
          touched = form?(action) ? retire_form?(action, wanted) : retire_rows(action, wanted)
          next unless touched

          # Nothing is left to answer here, so anything queued behind it was
          # waiting on a tap that will never come. Hand it back.
          if action.pending? && settled?(action)
            rescued.concat(Buddy::ProposalBuilder.claim_deferred(action))
            action.state      = :decided
            action.decided_at = Time.current
          end
          action.save!
        end

        rerender(action) if touched
        rescued
      end

      def retire_rows(action, wanted)
        buttons = Array(action.buttons).map(&:deep_dup)
        hit = false
        buttons.each { |btn|
          next unless wanted.include?(btn["merge_key"].to_s)
          next unless REPLACEABLE.include?(btn["status"].to_s)

          # Kept so the row can still render as "this DID run, and then got
          # replaced" rather than flattening into "never happened".
          btn["superseded_from"] = btn["status"]
          btn["status"]          = STATUS
          # The replacement owns that record now; undoing this row would delete it.
          btn["undoable"] = false
          hit = true
        }
        action.buttons = buttons if hit
        hit
      end

      # Nothing to rewrite on a form — retiring one is entirely the state change
      # in `retire`, so this only answers whether it's the right form.
      def retire_form?(action, wanted)
        return false unless action.pending?

        wanted.include?(action.tool_input["merge_key"].to_s)
      end

      def settled?(action)
        return true if form?(action)

        Array(action.buttons).none? { |b| b["status"].to_s == "pending" }
      end

      def form?(action)
        action.tool_name == Buddy::FormAction::TOOL_NAME
      end

      def rerender(action)
        message = action.byte_message
        return if message.nil?

        meta = (message.metadata || {}).merge("action_state" => action.decided? ? "decided" : "pending")
        meta = if form?(action)
          meta.merge("form" => (meta["form"] || {}).merge("status" => STATUS))
        else
          meta.merge("buttons" => action.buttons)
        end
        message.update!(metadata: meta)
        broadcast(action.user, message.reload)
      end

      def broadcast(user, message)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      end
    end
  end
end
