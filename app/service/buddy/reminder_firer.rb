module Buddy
  # Fires a BuddyReminder: creates the visible message in its
  # conversation, marks the reminder fired, broadcasts + notifies.
  # For `prompt` kind, also dispatches a fresh Buddy turn so the model
  # composes a contextual reply at fire-time (uses the same hidden-
  # trigger pattern as the quick-action buttons).
  module ReminderFirer
    module_function

    def fire!(reminder)
      return if reminder.fired_at.present? || reminder.cancelled_at.present?

      conversation = reminder.byte_conversation
      user         = reminder.user

      case reminder.kind
      when "reminder"
        deliver_plain_reminder(user, conversation, reminder)
      when "prompt"
        deliver_prompted_reminder(user, conversation, reminder)
      end

      # Recurring: roll fire_at forward to the next occurrence, keep
      # the row pending. Non-recurring: terminal fired_at.
      if reminder.recurring?
        next_fire = reminder.next_fire_at(from: Time.current)
        if next_fire
          reminder.update!(last_fired_at: Time.current, fire_at: next_fire)
        else
          # Bad recurrence spec - treat as one-shot rather than loop forever.
          reminder.update!(fired_at: Time.current, last_fired_at: Time.current)
        end
      else
        reminder.update!(fired_at: Time.current)
      end
    rescue => e
      # Firing a reminder failing is a data-integrity event: the user
      # asked to be reminded of something at a specific time and the
      # nudge did not fire. Route through Buddy::Errors so it shows up
      # in Slack immediately - a missed reminder in silent-log-only
      # would go unnoticed for hours.
      Buddy::Errors.report(
        section:   "reminder_firer.fire",
        exception: e,
        user:      reminder.user,
        extra:     { reminder_id: reminder.id, kind: reminder.kind },
      )
    end

    class << self
      private

      # A simple text message from Buddy. Delivered as inbound so the
      # standard notify path fires (push notification, presence-aware).
      def deliver_plain_reminder(user, conversation, reminder)
        Buddy::CompanionDelivery.deliver_plain(
          user:         user,
          conversation: conversation,
          text:         "⏰ Reminder: #{reminder.body}",
          metadata:     { kind: "buddy", source: "reminder", reminder_id: reminder.id },
          push_title:   reminder.body,
        )
      end

      # Trigger a Buddy turn as if the user tapped a quick action - the
      # reminder body becomes the synthetic prompt. Same hidden-message
      # pattern as Buddy::QuickActionsController.
      def deliver_prompted_reminder(user, conversation, reminder)
        Buddy::CompanionDelivery.deliver_prompt(
          user:         user,
          conversation: conversation,
          seed:         reminder.body,
          metadata:     {
            kind:        "buddy_trigger",
            hidden:      true,
            source:      "reminder",
            reminder_id: reminder.id,
          },
        )
      end
    end
  end
end
