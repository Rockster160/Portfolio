module Buddy
  # Shared delivery for the two things that make Buddy speak on its own:
  # time-based reminders (BuddyReminder, via Buddy::ReminderFirer) and
  # condition-based watches (BuddyWatch, via Buddy::WatchMatcher). Both
  # drop a message into the user's Buddy conversation, broadcast it, and
  # push. Owning it here keeps the delivery mechanics (and the Mac
  # round-trip thread) in ONE place so the two callers can't drift.
  #
  #   plain   - a fixed inbound nudge ("Reminder: ...") + push.
  #   prompt  - re-dispatches a fresh in-character Buddy turn seeded by
  #             the body (same hidden-trigger pattern as the quick-action
  #             chips), so the reply reads like Byte/Moss talking, not a
  #             canned string.
  module CompanionDelivery
    # The seed is the only thing on the input for a turn nobody asked for, and
    # two firings of the same watch or recurring reminder word it identically.
    # Prod 1318 was byte-for-byte 1315 from 45 minutes earlier, so the model
    # found its own announcement of the FIRST deploy sitting in history, read the
    # second as a duplicate, and sent "Already handled that one just now." to the
    # lock screen - the deploy it fired for went unmentioned.
    #
    # The clock stamp is what makes each firing distinct on its face, and the
    # rest of the frame says whose turn this is: nothing was said to Buddy, and
    # the reply IS the notification.
    SEED_FRAME = "[nothing was said to you - this fired on its own at %s, and your reply is the notification]".freeze

    class << self
      # `files` are ActiveStorage blobs (see ByteImageIntake) for the callers
      # that have a picture to show rather than only words — the doorbell
      # snapshot above all. Attached BEFORE the broadcast, because `as_wire` is
      # what the socket carries and a message that goes out without its
      # attachment renders as an empty bubble that nothing broadcasts again.
      #
      # `push: false` for a line that is a MECHANISM rather than something to
      # act on - a wait picking itself back up, where the step behind it posts
      # and pushes on its own account. Everything else buzzes: silence is how
      # somebody misses the thing they asked to be told about.
      def deliver_plain(user:, conversation:, text:, metadata:, push_title: nil, files: [], push: true)
        message = conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         text,
          metadata:     metadata,
          delivered_at: Time.current,
        )
        message.files.attach(files) if files.present?
        broadcast(user, message)
        notify(user, message, push_title: push_title || text) if push
        message
      end

      def deliver_prompt(user:, conversation:, seed:, metadata:)
        outbound = conversation.byte_messages.create!(
          user:      user,
          direction: :outbound,
          state:     :pending,
          body:      "#{frame(user)} #{seed}",
          metadata:  metadata,
        )

        # Deliver off the web threads via Sidekiq. `outbound` is a buddy
        # conversation message, so BuddyDeliverWorker routes it through
        # TurnDispatcher.deliver! and on to Buddy::GPT::Turn, without holding a
        # web-pool AR connection for the whole model call. Firing paths
        # (WatchMatcher / ReminderFirer) ride web requests and cron jobs;
        # neither should block on a streaming turn.
        BuddyDeliverWorker.perform_async(outbound.id)
        outbound
      end

      private

      def frame(user)
        format(SEED_FRAME, Buddy::TimeParser.friendly(Time.current, user: user))
      end

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
        # The wall tablet is a screen in a room, not a device that follows
        # anyone. It has the socket; a push here would only buzz a phone
        # elsewhere in the house. Same rule as ByteNotifier.
        return if message.byte_conversation&.kiosk?

        # OS shows the app name (Byte) and its icon, so the title is whatever
        # the caller hands over, unchanged. This used to staple a ⏰ onto every
        # one of them regardless of content - a glyph that leads EVERY
        # notification stops meaning anything by the second one. A caller whose
        # glyph says something (a deploy's outcome) still leads with it.
        WebPushNotifications.send_to_byte(
          title: push_title.to_s.truncate(160),
          tag:   "byte-#{message.id}",
          users: [user],
        )
      end
    end
  end
end
