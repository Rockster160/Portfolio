module Buddy
  # Renders an inline "here's what you've got set" management list into a Buddy
  # conversation, and cancels / restores individual rows when the person taps
  # the × (or Undo) on one.
  #
  # Both flavours live here: time-based BuddyReminders (one-shot + recurring)
  # and condition-based BuddyWatches ("when I get to Costco"). The list is a
  # ByteAction (tool_name "buddy_reminders_manage") attached to a fresh inbound
  # message and drawn by the manage-mode branch of the multi_select client
  # renderer. Removing a row flips the record's cancelled_at; Undo clears it.
  #
  # Deliberately NOT reusing the buddy_proposals / ProposalExecutor path: those
  # rows are "run this proposed action" and their receipts read "Done: X ✓",
  # which is the wrong voice for taking a reminder OFF a list. This owns its own
  # cancel/restore so the row state stays honest ("Removed" / back to active).
  module ReminderList
    module_function

    TOOL_NAME = "buddy_reminders_manage".freeze

    # Build + broadcast the list. Scoped to the USER (every conversation), so
    # "show my reminders" is a true management view, not just this thread's.
    # Posts into `conversation`. Returns the ByteAction, or nil when there's
    # nothing to show (a plain "nothing set" message is posted instead).
    def render(user:, conversation:)
      rows = rows_for(user)

      if rows.empty?
        post_message(user, conversation, "You don't have any reminders set right now.")
        return nil
      end

      message = post_message(user, conversation, "Here's what you've got set:", broadcast: false)

      action = ByteAction.create!(
        user:              user,
        byte_conversation: conversation,
        byte_message:      message,
        kind:              :custom,
        tool_name:         TOOL_NAME,
        multi_select:      true,
        buttons:           rows,
        tool_input:        {},
        # Long window: this list lives in the thread and cancels look up the
        # live record, so a later tap still works. Manage-mode cancels aren't
        # gated on expiry anyway.
        expires_at:        30.days.from_now,
      )

      message.update!(metadata: (message.metadata || {}).merge(
        "tool_name"         => TOOL_NAME,
        "action_request_id" => action.request_id,
        "action_kind"       => "custom",
        "action_state"      => "pending",
        "multi_select"      => true,
        "select_mode"       => "manage",
        "buttons"           => rows,
      ))

      broadcast(user, message.reload)
      action
    end

    # Take a row off the list: cancel the underlying reminder/watch and mark the
    # row "cancelled" (client strikes it through + offers Undo).
    def cancel!(action, button_id)
      set_cancelled(action, button_id, cancel: true)
    end

    # Put a removed row back: clear cancelled_at and mark the row "active" again.
    def restore!(action, button_id)
      set_cancelled(action, button_id, cancel: false)
    end

    class << self
      private

      def set_cancelled(action, button_id, cancel:)
        user    = action.user
        changed = false

        action.with_lock do
          buttons = (action.buttons || []).map(&:deep_dup)
          btn = buttons.find { |b| b["id"].to_i == button_id.to_i }
          if btn
            # A cycle is a RULE rather than a row, so there's no `cancelled_at`
            # to flip: switching it off tears down the block that's counting,
            # its break and any card still waiting, and Undo starts the next
            # block rather than un-deleting anything.
            if btn["record_type"].to_s == "cycle"
              set_cycle(user, action, btn, cancel)
            else
              record = record_for(user, btn)
              record&.update!(cancelled_at: cancel ? Time.current : nil)
            end
            btn["status"] = cancel ? "cancelled" : "active"
            action.buttons = buttons
            action.save!
            changed = true
          end
        end

        msg = action.byte_message
        if changed && msg
          msg.update!(metadata: (msg.metadata || {}).merge("buttons" => action.buttons))
          broadcast(user, msg)
        end
        action
      end

      def record_for(user, btn)
        case btn["record_type"].to_s
        when "reminder" then BuddyReminder.where(user_id: user.id).find_by(id: btn["record_id"])
        when "watch"    then BuddyWatch.where(user_id: user.id).find_by(id: btn["record_id"])
        end
      end

      def set_cycle(user, action, btn, cancel)
        cycle_id = btn["record_id"].to_s
        return Buddy::TimerCycle.cancel!(user, cycle_id) if cancel

        Buddy::TimerCycle.restart!(user, cycle_id, action.byte_conversation)
      end

      # What a row SAYS comes from Buddy::ReminderPresenter, shared with the
      # drawer's Reminders panel. What it CARRIES is this surface's own: a
      # sequential id so the client and respond handler address a row by one
      # number, and a status the cancel/restore taps flip.
      #
      # Only live rows here. A cancelled reminder is off the list as far as a
      # thread is concerned; the drawer panel is where you'd go to switch one
      # back on.
      def rows_for(user)
        Buddy::ReminderPresenter.rows(user).each_with_index.map { |row, i|
          {
            "id"          => i + 1,
            "record_type" => row[:type].to_s,
            "record_id"   => row[:record_id],
            "glyph"       => row[:glyph],
            "label"       => row[:label],
            "sublabel"    => row[:sublabel],
            "status"      => "active",
          }
        }
      end

      def post_message(user, conversation, body, broadcast: true)
        msg = conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         body,
          metadata:     { "kind" => "buddy_reply", "source" => "reminder_list" },
          delivered_at: Time.current,
        )
        broadcast(user, msg) if broadcast
        msg
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
