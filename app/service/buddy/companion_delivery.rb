module Buddy
  # Shared delivery for the two things that make Buddy speak on its own:
  # time-based reminders (BuddyReminder, via Buddy::ReminderFirer) and
  # condition-based watches (BuddyWatch, via Buddy::WatchMatcher). Both
  # drop a message into the user's Buddy conversation, broadcast it, and
  # push. Owning it here keeps the delivery mechanics (and the Mac
  # round-trip thread) in ONE place so the two callers can't drift.
  #
  #   plain   - a fixed inbound nudge ("⏰ Reminder: ...") + push.
  #   prompt  - re-dispatches a fresh in-character Buddy turn seeded by
  #             the body (same hidden-trigger pattern as the quick-action
  #             chips), so the reply reads like Byte/Moss talking, not a
  #             canned string.
  module CompanionDelivery
    class << self
      def deliver_plain(user:, conversation:, text:, metadata:, push_title: nil)
        message = conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         text,
          metadata:     metadata,
          delivered_at: Time.current,
        )
        broadcast(user, message)
        notify(user, message, push_title: push_title || text)
        message
      end

      def deliver_prompt(user:, conversation:, seed:, metadata:)
        outbound = conversation.byte_messages.create!(
          user:      user,
          direction: :outbound,
          state:     :pending,
          body:      "[scheduled prompt] #{seed}",
          metadata:  metadata,
        )

        # Executor.wrap so the thread returns its AR connection to the
        # pool cleanly even when Mac hangs.
        Thread.new {
          Rails.application.executor.wrap do
            begin
              response = ByteLocal.deliver(outbound, conversation: conversation)
              outbound.update!(state: response&.is_a?(Net::HTTPSuccess) ? :sent : :failed)
            rescue => e
              Rails.logger.warn("[Buddy::CompanionDelivery] deliver failed: #{e.class}: #{e.message}")
              outbound.update!(state: :failed) rescue nil
            end
          end
        }
        outbound
      end

      private

      def broadcast(user, message)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      end

      # Self-initiated pushes ignore presence - a reminder/watch fires when
      # it fires, regardless of whether the PWA thinks the user is looking.
      def notify(user, message, push_title:)
        # OS shows the app name (Byte); the title is the nudge itself.
        WebPushNotifications.send_to_byte(
          title: "⏰ #{push_title.to_s.truncate(160)}",
          tag:   "byte-#{message.id}",
          users: [user],
        )
      end
    end
  end
end
