# Off-loads outbound Byte turn handling from the Puma web threads onto Sidekiq.
# Previously each turn ran inline in a bare `Thread.new { ... }`, which held one
# of the (web-sized) AR connections for the ENTIRE 5-30s round-trip. With the
# pool sized to the web thread count, a handful of concurrent or slow turns
# drained it and unrelated web requests hit ConnectionTimeoutError. Sidekiq runs
# in its own process with its own pool, so this no longer competes with web
# traffic.
#
# Two destinations, and the split matters: :buddy runs the model turn IN RAILS
# (Buddy::GPT::Turn), while claude / bash still hand off over HTTP to whichever
# Mac the thread runs on (ByteConversation#machine).
class BuddyDeliverWorker
  include Sidekiq::Worker

  # No retry: neither destination is idempotent — one runs a billed model turn,
  # the other spawns a Claude Code process — so a retry would double-send.
  # Failure is already surfaced through the message's :failed state.
  sidekiq_options queue: :default, retry: false

  # The Mac didn't take the turn, as opposed to something breaking in here.
  HandoffFailed = Class.new(StandardError)

  def perform(message_id)
    message = ByteMessage.find_by(id: message_id)
    return if message.nil?

    conversation = message.byte_conversation
    if conversation&.buddy?
      # The single Buddy path: compaction, the model turn, state, broadcast.
      # Shared with the wake-drain (BuddyWakeWorker).
      Buddy::TurnDispatcher.deliver!(message)
    else
      deliver_plain(message, conversation)
    end
  end

  private

  # claude / bash: plain Mac handoff, reflect success in state + broadcast.
  # Untouched by Buddy's move into Rails — these modes need the Mac's real shell
  # and real repos.
  #
  # A non-success answer raises rather than being handled separately, so the one
  # rescue below covers both ways this fails: the Mac refusing it and the Mac
  # not being there at all.
  def deliver_plain(message, conversation)
    response = ByteLocal.deliver(message, conversation: conversation)
    raise(HandoffFailed, handoff_failure(conversation, response)) unless response.is_a?(Net::HTTPSuccess)

    message.update!(state: :sent)
    broadcast(message.reload)
  rescue => e
    Rails.logger.warn("[Byte] deliver worker crashed: #{e.class}: #{e.message}")
    message.update!(state: :failed) rescue nil
    broadcast(message.reload) rescue nil
    say_it_failed(message, e.message) if e.is_a?(HandoffFailed)
    report_failed_handoff(message, e)
  end

  # `deliver` answers nil when the Mac never picked up at all, which for the
  # laptop is almost always because the lid is shut.
  def handoff_failure(conversation, response)
    machine = ByteLocal.name_of(conversation&.machine || :mini)
    return "Couldn't reach #{machine} - it's asleep or offline, so this didn't run." if response.nil?

    "#{machine.upcase_first} didn't take that (#{response.code}), so it didn't run."
  end

  # A red state on the bubble is easy to miss on a phone, and a shell command
  # sent to a sleeping laptop looks exactly like one that's still running. So
  # the failure is said in the thread, as a reply, and pushed like any other.
  #
  # Not for a hidden prompt: nobody is looking at that thread for it, and the
  # error report below is how those surface.
  def say_it_failed(message, text)
    return if hidden?(message)

    note = message.byte_conversation.byte_messages.create!(
      user:         message.user,
      direction:    :inbound,
      state:        :delivered,
      body:         text,
      metadata:     {
        kind:        :system,
        source:      :handoff,
        in_reply_to: message.id,
      },
      delivered_at: Time.current,
    )
    broadcast(note)
    ByteNotifier.notify(message.user, note)
  rescue => e
    Rails.logger.warn("[Byte] couldn't post the handoff failure: #{e.class}: #{e.message}")
  end

  def hidden?(message)
    message.metadata.is_a?(Hash) && message.metadata["hidden"].present?
  end

  # The `:failed` state was supposed to be the whole signal — see the note on
  # `sidekiq_options` above. It isn't one for a message nobody can see: the
  # daily audit's prompt carries `hidden`, so a failed handoff sets the state on
  # a row that renders nowhere and the first sign of it is somebody noticing no
  # report arrived. A person's OWN message fails the same way, except a visible
  # bubble at least shows the state.
  #
  # Same reason Buddy::ReminderFirer reports: something the person is waiting
  # for silently didn't happen, and silent-log-only means hours before anyone
  # knows.
  def report_failed_handoff(message, exception)
    Buddy::Errors.report(
      section:   "byte.local_handoff",
      exception: exception,
      user:      message.user,
      extra:     {
        message_id:      message.id,
        conversation_id: message.byte_conversation_id,
        hidden:          hidden?(message),
      },
    )
  end

  def broadcast(message)
    MonitorChannel.broadcast_to(message.user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })
  end
end
