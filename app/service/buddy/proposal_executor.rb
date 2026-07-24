module Buddy
  # Runs after the user submits their checkbox choices. Walks each button
  # in the ByteAction; for checked ones (id in action.decision.value),
  # dispatches through the tool; for unchecked ones, marks cancelled.
  # Mutates buttons in-place with per-row status/result/error, persists
  # the updated action, then posts a single receipt message summarizing.
  module ProposalExecutor
    module_function

    def perform(byte_action_id)
      action = ByteAction.find(byte_action_id)
      user = action.user
      checked = Array(action.decision.is_a?(Hash) ? action.decision["value"] : action.decision).map(&:to_i).to_set

      buttons = (action.buttons || []).map(&:deep_dup)
      receipts = []

      buttons.each do |btn|
        id = btn["id"].to_i
        tool = Buddy::Tools[btn["tool_name"].to_sym]
        if tool.nil?
          btn["status"] = "failed"
          btn["error_message"] = "unknown tool #{btn['tool_name']}"
          next
        end

        unless checked.include?(id)
          btn["status"] = "cancelled"
          next
        end

        # Rehydrate a proposal-shaped hash so tool receipt/label procs can
        # read from ctx.proposal["payload"] uniformly.
        proposal_shape = { "id" => id, "payload" => btn["payload"], "tool_name" => btn["tool_name"] }
        ctx = Buddy::ToolContext.new(user, proposal: proposal_shape)

        count = (btn["count"] || 1).to_i
        outcomes = []
        count.times {
          outcomes << Buddy::Tools.dispatch(tool, symbolize_payload(btn["payload"]), ctx)
        }

        if outcomes.all? { |o| o[:ok] }
          btn["status"] = "executed"
          btn["result"] = outcomes.first[:data]
          receipts << safe_receipt(tool, outcomes.first[:data], ctx)
        elsif outcomes.any? { |o| o[:ok] }
          btn["status"] = "partial"
          btn["result"] = outcomes.map { |o| o[:data] }
          btn["error_message"] = outcomes.reject { |o| o[:ok] }.map { |o| o[:error] }.first
          receipts << "Partial: #{btn['label']}"
        else
          btn["status"] = "failed"
          btn["error_message"] = outcomes.first[:error]
        end
      end

      # Persist mutated buttons back onto both the action and its message.
      action.update!(buttons: buttons)
      msg = action.byte_message
      if msg
        new_meta = (msg.metadata || {}).merge(
          "action_state" => "decided",
          "buttons"      => buttons,
        )
        msg.update!(metadata: new_meta)
        broadcast(user, msg)
      end

      # Emit one summary receipt message.
      summary = compose_summary(buttons)
      unless summary.blank?
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

      # Expression cycle.
      if buttons.any? { |b| b["status"] == "executed" || b["status"] == "partial" }
        Buddy::ExpressionState.transition!(user, :proposals_executed)
      elsif buttons.all? { |b| b["status"] == "cancelled" }
        Buddy::ExpressionState.transition!(user, :proposals_cancelled)
      else
        Buddy::ExpressionState.transition!(user, :tool_failed)
      end

      action
    end

    class << self
      private

      def symbolize_payload(hash)
        (hash || {}).each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
      end

      def safe_receipt(tool, data, ctx)
        tool[:receipt].call(data, ctx).to_s
      rescue => e
        Rails.logger.warn("[Buddy::ProposalExecutor] receipt raised: #{e.class}: #{e.message}")
        nil
      end

      def compose_summary(buttons)
        done      = buttons.select { |b| b["status"] == "executed" }
        cancelled = buttons.select { |b| b["status"] == "cancelled" }
        failed    = buttons.select { |b| b["status"] == "failed" }
        partial   = buttons.select { |b| b["status"] == "partial" }

        parts = []
        parts << "Done: #{done.map { |b| b['label'] }.join(', ')} ✓" if done.any?
        parts << "Partial: #{partial.map { |b| b['label'] }.join(', ')}" if partial.any?
        parts << "Skipped: #{cancelled.map { |b| b['label'] }.join(', ')}" if cancelled.any?
        if failed.any?
          fails = failed.map { |b| "#{b['label']} — #{b['error_message']}" }
          parts << "Failed: #{fails.join('; ')}"
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
