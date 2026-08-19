module Buddy
  # Single delivery path for a Buddy outbound turn. Shared by the live send
  # (ByteMessageIntake via BuddyDeliverWorker) and the wake-drain
  # (BuddyWakeWorker), so a queued-then-woken turn behaves exactly like a fresh
  # send: compaction, then the model turn, then state and broadcast.
  #
  # Buddy runs IN RAILS now (Buddy::GPT::Turn against the OpenAI Responses API).
  # It no longer touches the Mac, which is why Buddy keeps working while the Mac
  # is asleep. Byte's claude and terminal modes still hand off to the Mac — see
  # BuddyDeliverWorker#deliver_plain, which is untouched by this.
  module TurnDispatcher
    module_function

    # How long a queued turn waits for the one ahead of it. Comfortably past the
    # client's own 120s request timeout, so a legitimately slow predecessor gets
    # waited out rather than abandoned.
    LOCK_WAIT_SECONDS = 150

    # Run `message`'s turn synchronously. Returns true on success.
    #
    # Turns are serialized per conversation. The Mac used to guarantee this with a
    # per-conversation mutex in its handler; moving Buddy into Rails put every
    # turn in its own Sidekiq job, so the guarantee has to be re-established here.
    # It matters wherever two turns can overlap in one conversation: a person
    # firing off two messages in quick succession, and anything that seeds a
    # turn of its own while one is running (a reminder firing, a watch
    # tripping). Unserialized, two turns build history concurrently and the
    # second can miss the first's reply entirely.
    def deliver!(message)
      conversation = message.byte_conversation
      user         = conversation.user

      attempt = ByteConversation.with_advisory_lock_result(
        lock_name(conversation), timeout_seconds: LOCK_WAIT_SECONDS
      ) { run_turn!(message, conversation, user) }

      return attempt.result if attempt.lock_was_acquired?

      # Waited the full window, so the holder is wedged rather than working.
      # Proceeding risks an out-of-order reply; dropping the turn loses the
      # person's message outright. Take the cosmetic problem over the silent one.
      Rails.logger.warn(
        "[Buddy] turn lock timeout on conversation=#{conversation.id}; running unserialized",
      )
      run_turn!(message, conversation, user)
    rescue StandardError => e
      Rails.logger.warn("[Buddy] deliver failed: #{e.class}: #{e.message}")
      message.update!(state: :failed) rescue nil
      broadcast_message(user, message.reload) rescue nil
      false
    end

    def lock_name(conversation)
      "buddy_turn:#{conversation.id}"
    end

    def run_turn!(message, conversation, user)
      compacted = Buddy::Compactor.compact!(conversation) if Buddy::Compactor.should_compact?(conversation)
      # Everything before the recap has just left Buddy's context, so this is
      # the last turn that could write down a thought this thread was working
      # on. Only on a compaction that actually happened: a failed one truncates
      # nothing, and the exchange is still there to be noticed later.
      settle_ideas(conversation, over: true) if compacted

      # Anything that came through ByteMessageIntake is already `sent` — the
      # server had it long before a worker got here. What this still catches is
      # the drained-from-sleep path, where BuddyWakeWorker hands the message
      # back as `pending` on its way out of the queue.
      #
      # Guarded so an unchanged message isn't rebroadcast: a second paint of a
      # bubble nobody changed is exactly what used to knock it backwards.
      unless message.sent?
        message.update!(state: :sent)
        broadcast_message(user, message.reload)
      end

      Buddy::GPT::Turn.run!(message).tap {
        settle_ideas(conversation)
        flag_compile(conversation, message)
      }
    end

    # Note that there was real conversation here, so Buddy::Compile can read it
    # back once it's over. Only for a message the PERSON actually wrote: a
    # reminder firing or a briefing seeding itself is not somebody telling their
    # companion something, and compiling those would spend a model call on
    # Buddy's own output.
    #
    # Every qualifying turn re-flags, which pushes the compile back — so one
    # compile covers a whole conversation rather than one per message.
    def flag_compile(conversation, message)
      return unless message.outbound?
      return if message.metadata.is_a?(Hash) && message.metadata["hidden"]

      Buddy::Compile.flag!(conversation)
    rescue StandardError => e
      Rails.logger.warn("[Buddy] compile flag failed: #{e.class}: #{e.message}")
    end

    # A stretch about a held idea ends when the conversation moves off it, and
    # the end of a turn is the only moment that's visible from — from here the
    # reply that answered the new subject already exists, so a topic change
    # looks like one instead of like a single stray question mid-thought.
    # Queued rather than run: the note is about a thought they've moved on from,
    # and nothing about it is worth holding this conversation's lock.
    def settle_ideas(conversation, over: false)
      BuddyIdeaSettleWorker.perform_async(conversation.id, over)
    rescue StandardError => e
      Rails.logger.warn("[Buddy] idea settle enqueue failed: #{e.class}: #{e.message}")
    end

    def broadcast_message(user, message)
      MonitorChannel.broadcast_to(user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.as_wire },
      })
    rescue StandardError => e
      Rails.logger.warn("[Buddy] message broadcast failed: #{e.class}: #{e.message}")
    end
  end
end
