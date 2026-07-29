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
            record = record_for(user, btn)
            record&.update!(cancelled_at: cancel ? Time.current : nil)
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

      # Time-based reminders first (soonest to fire on top), then condition
      # watches (oldest first). Row ids are sequential across both so the client
      # + respond handler address a row by a single id.
      def rows_for(user)
        tz  = user.timezone
        idx = 0
        rows = []

        BuddyReminder.pending.where(user_id: user.id).order(:fire_at).limit(50).each do |r|
          idx += 1
          recurring = r.recurring?
          rows << {
            "id"          => idx,
            "record_type" => "reminder",
            "record_id"   => r.id,
            "glyph"       => recurring ? "🔁" : "⏰",
            "label"       => r.body.to_s.truncate(80),
            "sublabel"    => recurring ? recurrence_text(r) : r.fire_at.in_time_zone(tz).strftime("%a %-I:%M %p"),
            "status"      => "active",
          }
        end

        BuddyWatch.active.where(user_id: user.id).order(:created_at).limit(50).each do |w|
          idx += 1
          rows << {
            "id"          => idx,
            "record_type" => "watch",
            "record_id"   => w.id,
            "glyph"       => watch_glyph(w.trigger_scope),
            "label"       => w.body.to_s.truncate(80),
            "sublabel"    => watch_when(w),
            "status"      => "active",
          }
        end

        rows
      end

      # Mirrors schedule_reminder's receipt phrasing for a recurrence hash.
      def recurrence_text(reminder)
        rec  = reminder.recurrence || {}
        hhmm = (Time.zone.parse(rec["at"].to_s) rescue nil)
        tstr = hhmm ? hhmm.strftime("%-I:%M %p") : rec["at"].to_s
        base = case rec["kind"]
        when "daily"    then "every day"
        when "weekdays" then "every weekday"
        when "weekly"   then "every #{rec["weekday"].to_s.capitalize}"
        when "monthly"  then "day #{rec["day"]} monthly"
        else                 "on a schedule"
        end
        "#{base} at #{tstr}"
      end

      def watch_glyph(scope)
        case scope.to_s
        when "travel"           then "📍"
        when "chore_completion" then "✅"
        when "event"            then "📝"
        when "agenda_item"      then "📅"
        when "deploy"           then "🚀"
        else                         "🔔"
        end
      end

      def watch_when(watch)
        (watch.metadata.is_a?(Hash) ? watch.metadata["human_when"].to_s.presence : nil) || watch.trigger_scope.to_s
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
