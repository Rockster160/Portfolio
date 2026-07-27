module Buddy
  # Single delivery path for a Buddy outbound turn → the Mac. Shared by the
  # live send (ByteController#dispatch_message, wrapped in a thread) and the
  # wake-drain (BuddyWakeWorker, already on Sidekiq). Keeping it in one place
  # means the queued-then-woken path behaves exactly like a fresh send:
  # compaction, state transition, broadcast, and sleep-on-Mac-failure.
  module TurnDispatcher
    module_function

    # Deliver `message` synchronously. Returns true on a Mac success.
    def deliver!(message)
      conversation = message.byte_conversation
      user         = conversation.user

      if conversation.buddy? && Buddy::Compactor.should_compact?(conversation)
        Buddy::Compactor.compact!(conversation)
      end

      response = ByteLocal.deliver(message, conversation: conversation)
      ok       = response.is_a?(Net::HTTPSuccess)
      message.update!(state: ok ? :sent : :failed)
      broadcast_message(user, message.reload)

      # Mac unreachable on a Buddy turn: put Buddy to sleep so later turns
      # hold in the queue instead of spawning more failing deliveries. No
      # canned reply — the persistent sleeping chip communicates the state.
      if conversation.buddy? && !ok && !Buddy::SleepGuard.sleeping?(user)
        Buddy::SleepGuard.sleep_until!(user, 3.minutes.from_now)
      end

      ok
    rescue => e
      Rails.logger.warn("[Buddy] deliver failed: #{e.class}: #{e.message}")
      message.update!(state: :failed) rescue nil
      broadcast_message(user, message.reload) rescue nil
      false
    end

    def broadcast_message(user, message)
      MonitorChannel.broadcast_to(user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.as_wire },
      })
    rescue => e
      Rails.logger.warn("[Buddy] message broadcast failed: #{e.class}: #{e.message}")
    end
  end
end
