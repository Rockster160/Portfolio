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
        message = conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         "⏰ Reminder: #{reminder.body}",
          metadata:     { kind: "buddy", source: "reminder", reminder_id: reminder.id },
          delivered_at: Time.current,
        )
        broadcast(user, message)
        notify_direct(user, message)
      end

      # Trigger a Buddy turn as if the user tapped a quick action - the
      # reminder body becomes the synthetic prompt. Same hidden-message
      # pattern as Buddy::QuickActionsController.
      def deliver_prompted_reminder(user, conversation, reminder)
        outbound = conversation.byte_messages.create!(
          user:      user,
          direction: :outbound,
          state:     :pending,
          body:      "[scheduled prompt] #{reminder.body}",
          metadata:  {
            kind:         "buddy_trigger",
            hidden:       true,
            source:       "reminder",
            reminder_id:  reminder.id,
          },
        )

        # Reuse the same delivery-to-Mac path everything else uses.
        # Executor.wrap so the thread returns its AR connection to the
        # pool cleanly even when Mac hangs.
        Thread.new {
          Rails.application.executor.wrap do
            begin
              response = ByteLocal.deliver(outbound, conversation: conversation)
              outbound.update!(state: response&.is_a?(Net::HTTPSuccess) ? :sent : :failed)
            rescue => e
              Rails.logger.warn("[BuddyReminder] deliver failed: #{e.class}: #{e.message}")
              outbound.update!(state: :failed) rescue nil
            end
          end
        }
      end

      def broadcast(user, message)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      end

      # Reminder pushes ignore presence - a scheduled nudge fires when
      # it fires, regardless of whether the PWA thinks the user is
      # currently looking. Same shape used for proposal notifications.
      def notify_direct(user, message)
        WebPushNotifications.send_to_byte(
          title: message.byte_conversation&.display_name.presence || "Buddy",
          body:  "⏰ #{message.body.to_s.sub(/\A⏰ Reminder: /, '').truncate(160)}",
          tag:   "byte-#{message.id}",
          users: [user],
        )
      end
    end
  end
end
