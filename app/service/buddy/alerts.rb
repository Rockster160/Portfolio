module Buddy
  # A message that stands for something OUTSTANDING, and stops standing for it
  # when the thing is dealt with.
  #
  # Everything else Buddy says is news: it happened, it's said, it's over. A
  # condition isn't like that. "The laundry gate is open" is true until somebody
  # closes the gate, and a second message an hour later saying the same thing
  # doesn't help - what helps is the FIRST message no longer saying it once it
  # stops being true.
  #
  # So an alert owns its bubble for as long as it is open. `raise!` posts it and
  # pushes; `raise!` again on the same key rewrites that same bubble in place,
  # counting the occurrence rather than adding another notification for a fact
  # already on screen; `resolve!` rewrites it one last time, into the record
  # that it was handled.
  #
  # Nothing here is specific to any one condition. The KEY is the caller's, and
  # it is the whole of the coupling between the thing that notices and the thing
  # that clears it - which are rarely the same sensor, the same task, or even
  # the same day.
  #
  # Why the repeats don't buzz again: the push exists to tell somebody something
  # they don't know. They know - they were told when it opened, and the bubble
  # has said so ever since. That is the opposite of the rolled-up "3× someone at
  # the door", which destroys three separate events; here there is one event
  # (the condition began) and a count of how many times it has been seen since,
  # which is on the bubble in words. A caller that genuinely wants a buzz per
  # occurrence has `Buddy.say` for the occurrence and this for the state.
  module Alerts
    module_function

    KIND = :alert

    # Open one, or tell an open one that it happened again. Returns the
    # BuddyAlert, or nil when there was nothing to say it to - no key, no words,
    # or nobody with a companion thread to put it in.
    def raise!(user:, key:, body:, conversation: nil)
      key  = key.to_s.strip
      body = body.to_s.strip
      return nil if key.empty? || body.empty?

      conversation ||= ::Buddy::CompanionRelay.conversation_for(user)
      return nil if conversation.nil?

      open = ::BuddyAlert.open_for(user, key)
      open ? seen_again!(open, body) : open!(user, conversation, key, body)
    end

    # It's been dealt with. `body` is what the bubble should say now; without
    # one it keeps its own words and simply stops reading as outstanding.
    #
    # Returns nil when nothing was open under that key, so a task that clears a
    # condition on every pass can tell "I just fixed something" from "it was
    # already fine" without keeping track itself.
    def resolve!(user:, key:, body: nil)
      close!(::BuddyAlert.open_for(user, key.to_s.strip), :resolved, body)
    end

    # Stop asking. This is a PERSON saying they don't want it standing there any
    # more, and it is deliberately not the same fact as the condition clearing —
    # the bubble says "let go of", never "resolved", because nobody checked.
    #
    # It exists because an alert nobody deals with is worse than one nobody
    # sees: while it stands open the key is taken, so every later occurrence
    # lands on the same buried bubble instead of announcing itself. Letting go
    # frees the key, and the next occurrence opens fresh and buzzes like the
    # first one did.
    def dismiss!(user:, id:)
      close!(::BuddyAlert.status_open.where(user_id: user.id).find_by(id: id), :dismissed, nil)
    end

    def close!(alert, status, body)
      return nil if alert.nil?

      alert.update!(status: status, resolved_at: Time.current, resolution: body.to_s.strip.presence)
      repaint!(alert)
      broadcast_outstanding!(alert.user)
      alert
    end

    # ---- what is still standing ----------------------------------------------

    # Every open alert, oldest first. The bubble is where the words are, but a
    # thread moves on and a bubble raised on Tuesday is a hundred messages up by
    # Thursday - this is what the pinned strip is drawn from, and it is read
    # fresh from the database on every load, so nothing can be lost by being
    # scrolled past.
    def outstanding(user)
      ::BuddyAlert.outstanding.where(user_id: user.id).to_a
    end

    def outstanding_wire(user)
      outstanding(user).map(&:strip_wire)
    end

    def broadcast_outstanding!(user)
      MonitorChannel.broadcast_to(user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :alerts, alerts: outstanding_wire(user) },
      })
    end

    def open!(user, conversation, key, body)
      now   = Time.current
      alert = ::BuddyAlert.create!(
        user:              user,
        byte_conversation: conversation,
        key:               key,
        body:              body,
        status:            :open,
        raised_at:         now,
        last_raised_at:    now,
        raised_count:      1,
      )
      message = ::Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         body,
        metadata:     { kind: KIND, alert: alert.wire },
        push_title:   body,
      )
      alert.update!(byte_message_id: message.id, metadata: alert.metadata.merge("notified_at" => now.iso8601))
      broadcast_outstanding!(user)
      alert
    end

    # The condition is still true. The wording is taken from the newest telling
    # - a caller that puts a reading in the sentence ("garage open 40 minutes")
    # means the new one - and the count and the clock are what make the bubble
    # say that this is not simply the same moment still on screen.
    def seen_again!(alert, body)
      now   = Time.current
      buzz  = alert.push_again?
      attrs = { body: body, raised_count: alert.raised_count + 1, last_raised_at: now }
      attrs[:metadata] = alert.metadata.merge("notified_at" => now.iso8601) if buzz
      alert.update!(attrs)

      message = repaint!(alert)
      broadcast_outstanding!(alert.user)
      # A repeat while the bubble is fresh is something they were told about
      # minutes ago. A repeat a day later has outlived their memory of it, and
      # staying silent then is exactly how one ignored alert goes on to eat
      # every occurrence after it.
      ::Buddy::CompanionDelivery.notify(alert.user, message, push_title: body) if buzz && message
      alert
    end

    # Rewrite the bubble this alert already owns, in place. `update: true` is
    # what tells the client this is not a new message: no unread count, no
    # notice, no pet reacting to an old bubble moving - just the words changing
    # under the same timestamp, which is the whole point.
    #
    # A missing message is not an error. The bubble can be deleted from the
    # thread, and the alert outliving it is better than a resolve that raises.
    def repaint!(alert)
      message = alert.byte_message
      return nil if message.nil?

      message.update!(
        body:     alert.status_resolved? ? (alert.resolution.presence || alert.body) : alert.body,
        metadata: message.metadata.to_h.merge("alert" => alert.wire),
      )
      MonitorChannel.broadcast_to(alert.user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.as_wire, update: true },
      })
      message
    end
  end
end
