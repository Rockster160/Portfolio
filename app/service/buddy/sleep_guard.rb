module Buddy
  # "Buddy is sleeping" state, driven by Anthropic API usage-cap errors
  # that come back through the Mac. When Mac's claude -p reports "out
  # of extra usage / resets HH:MMam", Rails records the reset time on the
  # user's Buddy conversations (byte_conversations.buddy_sleep_until) and
  # Buddy stops trying to dispatch turns until that time passes. Sleep is
  # account-wide (the Mac is out of usage for every thread), so it fans out
  # across all the user's Buddy threads. Incoming messages while asleep get an
  # immediate in-character "sleeping until X" reply instead of a
  # dispatch-and-fail.
  module SleepGuard
    module_function

    # Regex that matches the shape of Anthropic's usage-cap error text.
    # Tries to be forgiving about capitalization and connector chars.
    # Extracts a time like "11:20am" and optional "(America/Denver)".
    ERROR_RX = /out of (?:extra )?usage.*?resets\s+(?<time>\d{1,2}(?::\d{2})?\s*(?:am|pm)?)(?:\s*\(?(?<tz>[A-Za-z_\/\-]+)\)?)?/i

    # Parse the message body from Mac and, if it's a usage-cap error,
    # extract the ISO reset timestamp. Returns nil on no match.
    def parse_reset_time(body, default_tz: "America/Denver")
      m = ERROR_RX.match(body.to_s)
      return nil unless m

      tz_name = m[:tz].presence || default_tz
      time_str = m[:time].to_s.strip
      begin
        zone = ActiveSupport::TimeZone[tz_name] || Time.zone
        parsed = zone.parse(time_str)
        return nil unless parsed

        # If the parsed time is in the past for today, roll to tomorrow.
        parsed += 1.day if parsed < zone.now
        parsed
      rescue
        nil
      end
    end

    # Sleep is account-wide (the Mac is out of usage for every thread), so it
    # fans out across all the user's Buddy conversations — but the sleep state
    # itself now lives per-conversation. Each thread stashes the face it was
    # resting on so `wake!` can restore it rather than flattening everyone to
    # neutral.
    def buddy_conversations(user)
      user.byte_conversations.buddy
    end

    # Mark the user asleep until `until_time`, broadcast the sleep state (so
    # the client raises the persistent sleeping chip), shift every thread's face
    # to sleeping, and schedule the wake-drain for when the window passes.
    def sleep_until!(user, until_time)
      return if until_time.nil? || until_time < Time.current

      buddy_conversations(user).find_each do |convo|
        # Don't clobber a stashed prior face if we're just extending sleep.
        unless convo.buddy_expression == "sleeping"
          convo.update_column(:metadata, convo.metadata.merge("pre_sleep_expression" => convo.buddy_expression))
        end
        convo.update_column(:buddy_sleep_until, until_time)
        Buddy::ExpressionState.set(convo, :sleeping)
      end
      broadcast_sleep(user, until_time)
      BuddyWakeWorker.perform_at(until_time, user.id)
    end

    def sleeping?(user)
      buddy_conversations(user).where("buddy_sleep_until > ?", Time.current).exists?
    end

    # Clear the sleep state across every thread, restore each one's pre-sleep
    # face, and tell the client to lower the sleeping chip. Idempotent — safe to
    # call when the user is already awake. Draining the held queue is the
    # caller's job (BuddyWakeWorker) so it never blocks a request thread.
    def wake!(user)
      buddy_conversations(user).where.not(buddy_sleep_until: nil).find_each do |convo|
        prior = convo.metadata["pre_sleep_expression"].presence || "neutral"
        convo.update_column(:buddy_sleep_until, nil)
        convo.update_column(:metadata, convo.metadata.except("pre_sleep_expression"))
        Buddy::ExpressionState.set(convo, prior)
      end
      broadcast_wake(user)
    end

    # Called on message dispatch. If the sleep window has passed, hand off to
    # the wake worker (clears state + drains the queue) without blocking the
    # request on Mac delivery.
    def maybe_wake!(user)
      return unless buddy_conversations(user)
        .where.not(buddy_sleep_until: nil)
        .where("buddy_sleep_until <= ?", Time.current)
        .exists?

      BuddyWakeWorker.perform_async(user.id)
    end

    # Every queued Buddy turn for this user, oldest first — the wake order.
    def queued_messages(user)
      ByteMessage
        .joins(:byte_conversation)
        .where(byte_conversations: { user_id: user.id, mode: ByteConversation.modes[:buddy] })
        .where(direction: ByteMessage.directions[:outbound], state: ByteMessage.states[:queued])
        .chronological
    end

    def broadcast_sleep(user, until_time)
      MonitorChannel.broadcast_to(user, {
        id:      :byte,
        channel: :byte,
        data:    {
          kind:        :buddy_sleep,
          sleep_until: until_time&.iso8601,
          wake_string: wake_string(user),
        },
      })
    rescue => e
      Rails.logger.warn("[Buddy] sleep broadcast failed: #{e.class}: #{e.message}")
    end

    def broadcast_wake(user)
      MonitorChannel.broadcast_to(user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :buddy_wake },
      })
    rescue => e
      Rails.logger.warn("[Buddy] wake broadcast failed: #{e.class}: #{e.message}")
    end

    # Friendly wake-time string for the sleeping reply. Sleep is set across all
    # threads at once, so the latest window is the wake time.
    def wake_string(user)
      until_time = buddy_conversations(user).maximum(:buddy_sleep_until)
      return "later" if until_time.nil?

      until_time
        .in_time_zone(user.timezone)
        .strftime("%-I:%M %p")
    end

    # Buddy's in-character reply while asleep, named for whichever pet is asleep.
    # `conversation` is optional because some callers only know the user; without
    # a thread the honest answer is their default pet.
    def sleeping_reply_body(user, conversation=nil)
      theme = conversation&.buddy_theme.presence || ByteConversation.default_theme_for(user)
      name  = Buddy::Themes.name_for(theme)
      "💤 #{name} is sleeping right now. They'll be back up at #{wake_string(user)}."
    end
  end
end
