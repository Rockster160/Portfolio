# Off-loads outbound Byte turn handling from the Puma web threads onto Sidekiq.
# Previously each turn ran inline in a bare `Thread.new { ... }`, which held one
# of the (web-sized) AR connections for the ENTIRE 5-30s round-trip. With the
# pool sized to the web thread count, a handful of concurrent or slow turns
# drained it and unrelated web requests hit ConnectionTimeoutError. Sidekiq runs
# in its own process with its own pool, so this no longer competes with web
# traffic.
#
# Two destinations, and the split matters: :buddy runs the model turn IN RAILS
# (Buddy::GPT::Turn), while claude / bash still hand off to the Mac over HTTP.
class BuddyDeliverWorker
  include Sidekiq::Worker

  # No retry: neither destination is idempotent — one runs a billed model turn,
  # the other spawns a Claude Code process — so a retry would double-send.
  # Failure is already surfaced through the message's :failed state.
  sidekiq_options queue: :default, retry: false

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
  def deliver_plain(message, conversation)
    response = ByteLocal.deliver(message, conversation: conversation)
    ok       = response.is_a?(Net::HTTPSuccess)
    message.update!(state: ok ? :sent : :failed)
    broadcast(message.reload)
  rescue => e
    Rails.logger.warn("[Byte] deliver worker crashed: #{e.class}: #{e.message}")
    message.update!(state: :failed) rescue nil
    broadcast(message.reload) rescue nil
  end

  def broadcast(message)
    MonitorChannel.broadcast_to(message.user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })
  end
end
