module Buddy
  # Executes checkbox proposals on a ByteAction. There are two shapes:
  #
  #   Incremental (Buddy checklists, the live path): `execute_ids` names the
  #   specific rows the user just checked. Each is run; every OTHER row is
  #   left pending and still tappable. The action only flips to :decided once
  #   nothing is left pending. This is what lets a checkbox trigger the moment
  #   it's tapped without cancelling the rows the user hasn't gotten to yet.
  #
  #   One-shot (legacy / non-Buddy multi-selects): `execute_ids` is nil, so
  #   the checked set is read from the recorded decision and every UNchecked
  #   row is a decline -> cancelled. The whole action decides in one pass.
  #
  # Rows already resolved (executed/partial/failed) are never re-run, so
  # repeated taps and overlapping jobs are idempotent. The read-execute-write
  # runs under `with_lock` so concurrent taps can't clobber the buttons JSON.
  module ProposalExecutor
    module_function

    def perform(byte_action_id, execute_ids=nil)
      action = ByteAction.find(byte_action_id)
      user = action.user
      incremental = !execute_ids.nil?

      just_done = []
      just_partial = []
      just_failed = []
      buttons = nil
      deferred = []

      action.with_lock do
        # Re-read inside the lock so an earlier overlapping tap's writes are
        # visible — that's what makes "skip already-resolved" actually skip.
        buttons = (action.buttons || []).map(&:deep_dup)

        requested = if incremental
          Array(execute_ids).to_set(&:to_i)
        else
          Array(action.decision.is_a?(Hash) ? action.decision["value"] : action.decision).to_set(&:to_i)
        end

        buttons.each do |btn|
          id = btn["id"].to_i
          # Already acted on — never re-run (idempotent across repeat taps).
          next if RESOLVED.include?(btn["status"].to_s)

          unless requested.include?(id)
            # Incremental leaves untouched rows pending (still tappable); the
            # one-shot path treats an unchecked row as a decline.
            btn["status"] = "cancelled" unless incremental
            next
          end

          tool = Buddy::Tools[btn["tool_name"].to_sym]
          if tool.nil?
            btn["status"] = "failed"
            btn["error_message"] = "unknown tool #{btn["tool_name"]}"
            just_failed << btn
            next
          end

          # Rehydrate a proposal-shaped hash so tool receipt/label procs can
          # read from ctx.proposal["payload"] uniformly.
          proposal_shape = { "id" => id, "payload" => btn["payload"], "tool_name" => btn["tool_name"] }
          ctx = Buddy::ToolContext.new(user, proposal: proposal_shape, conversation: action.byte_conversation)

          count = (btn["count"] || 1).to_i
          outcomes = []
          count.times {
            outcomes << Buddy::Tools.dispatch(tool, symbolize_payload(btn["payload"]), ctx)
          }

          if outcomes.all? { |o| o[:ok] }
            btn["status"] = "executed"
            btn["result"] = outcomes.first[:data]
            btn["receipt"] = safe_receipt(tool, outcomes.first[:data], ctx)
            just_done << btn
          elsif outcomes.any? { |o| o[:ok] }
            btn["status"] = "partial"
            btn["result"] = outcomes.map { |o| o[:data] }
            btn["error_message"] = outcomes.reject { |o| o[:ok] }.map { |o| o[:error] }.first
            just_partial << btn
          else
            btn["status"] = "failed"
            btn["error_message"] = outcomes.first[:error]
            just_failed << btn
          end
        end

        # The action is done only when no row is still awaiting a tap.
        all_resolved = buttons.none? { |b| b["status"].to_s == "pending" }
        executed_ids = buttons.select { |b| RESOLVED.include?(b["status"].to_s) }.map { |b| b["id"] }

        action.buttons  = buttons
        action.decision = { "value" => executed_ids, "source" => "user" }
        if all_resolved && action.pending?
          action.state      = :decided
          action.decided_at = Time.current
          # Anything the model queued BEHIND this checklist has been waiting for
          # exactly this moment. Claimed under the lock so two taps racing can't
          # both send it; run below, outside the lock, since these post messages
          # and broadcast.
          deferred = Buddy::ProposalBuilder.claim_deferred(action)
        end
        action.save!
      end

      # Broadcast the re-rendered checklist. Incremental stays "pending" while
      # rows remain so the client keeps the untouched checkboxes live.
      msg = action.byte_message
      if msg
        new_meta = (msg.metadata || {}).merge(
          "action_state" => action.decided? ? "decided" : "pending",
          "buttons"      => buttons,
        )
        msg.update!(metadata: new_meta)
        broadcast(user, msg)
      end

      # Receipt covers ONLY what ran this pass — incremental must not re-list
      # the whole checklist on every tap.
      summary = compose_summary(just_done, just_partial, just_failed, incremental ? [] : buttons.select { |b| b["status"] == "cancelled" })
      if summary.present?
        receipt = action.byte_conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         summary,
          metadata:     { kind: :buddy_receipt, action_id: action.id },
          delivered_at: Time.current,
        )
        broadcast(user, receipt)
      end

      # Last, so it reads in the order it happened: the checklist result, then
      # whatever was waiting on it. Only runs if something actually executed — a
      # follow-up announcing a move the person cancelled is the same lie in
      # slower motion.
      if deferred.any?
        ran = buttons.any? { |b| b["status"].to_s == "executed" }
        Buddy::ProposalBuilder.run_deferred!(action, deferred, executed: ran)
      end

      # NOTE: tapping a checkbox no longer moves the pet's face. The mood is a
      # persistent expression Buddy sets deliberately via [[mood:]]; a mechanical
      # confirm/undo shouldn't yank it to happy-then-neutral (that flash-then-
      # revert was the exact bug we're fixing). The face stays as Buddy left it.

      action
    end

    RESOLVED = %w[executed partial failed].freeze

    # Uncheck-to-undo for a Level-2 row. Reverses every stashed revert
    # descriptor on the button (a counted row carries several), flips it to
    # `undone`, and broadcasts the re-rendered checklist + a short receipt. A
    # revert that's already gone (e.g. the completion was deleted elsewhere) is
    # treated as success — the end state is the same.
    def undo!(byte_action_id, button_id)
      action = ByteAction.find(byte_action_id)
      user = action.user
      summary = nil

      action.with_lock do
        buttons = (action.buttons || []).map(&:deep_dup)
        btn = buttons.find { |b| b["id"].to_i == button_id.to_i }
        return action if btn.nil?
        return action unless btn["undoable"] && btn["status"].to_s == "executed"

        result  = btn["result"] || {}
        reverts = result["reverts"].presence || [result["revert"]].compact
        summaries = reverts.filter_map { |rv| revert_one(rv) }

        btn["status"]    = "undone"
        btn["undoable"]  = false
        result["undone"] = true
        btn["result"]    = result
        summary = summaries.first

        action.buttons = buttons
        action.save!
      end

      msg = action.byte_message
      if msg
        msg.update!(metadata: (msg.metadata || {}).merge("buttons" => action.buttons))
        broadcast(user, msg)
      end

      if summary
        receipt = action.byte_conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         "Undone - #{summary}",
          metadata:     { kind: :buddy_receipt, action_id: action.id },
          delivered_at: Time.current,
        )
        broadcast(user, receipt)
      end

      action
    end

    class << self
      private

      def symbolize_payload(hash)
        (hash || {}).transform_keys(&:to_sym)
      end

      # Reverse one descriptor; a row that's "already gone" counts as undone.
      def revert_one(descriptor)
        Buddy::Reverter.call(descriptor)
      rescue StandardError => e
        Rails.logger.warn("[Buddy::ProposalExecutor] undo revert failed: #{e.class}: #{e.message}")
        nil
      end

      def safe_receipt(tool, data, ctx)
        tool[:receipt].call(data, ctx).to_s
      rescue StandardError => e
        Rails.logger.warn("[Buddy::ProposalExecutor] receipt raised: #{e.class}: #{e.message}")
        nil
      end

      # Receipt is built from the rows that transitioned THIS pass (plus, for
      # the one-shot path, the rows it just cancelled) — never the whole
      # checklist, so an incremental tap only ever reports its own row.
      def compose_summary(done, partial, failed, cancelled)
        parts = []
        parts << "Done: #{done.pluck("label").join(", ")} ✓" if done.any?
        parts << "Partial: #{partial.pluck("label").join(", ")}" if partial.any?
        parts << "Skipped: #{cancelled.pluck("label").join(", ")}" if cancelled.any?
        if failed.any?
          fails = failed.map { |b| "#{b["label"]} - #{b["error_message"]}" }
          parts << "Failed: #{fails.join("; ")}"
        end
        parts.join("\n")
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
