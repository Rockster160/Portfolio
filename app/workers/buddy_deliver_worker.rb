# Off-loads the Byte → Mac delivery round-trip from the Puma web threads
# onto Sidekiq. Previously each outbound turn ran the delivery inline in a
# bare `Thread.new { Rails.application.executor.wrap { ... } }`, which held
# one of the (web-sized) AR connections for the ENTIRE 5-30s Mac HTTP
# round-trip (context build + optional 30s compaction + deliver). With the
# pool sized to the web thread count, a handful of concurrent or slow turns
# drained it and unrelated web requests hit ConnectionTimeoutError. Sidekiq
# runs in its own process with its own connection pool, so the delivery no
# longer competes with web traffic.
class BuddyDeliverWorker
  include Sidekiq::Worker

  # No retry: a Mac delivery is NOT idempotent — it spawns a Claude turn —
  # so a retry would double-send. Failure is already surfaced via the
  # message's :failed state and the sleep-on-Mac-failure path inside
  # TurnDispatcher.
  sidekiq_options queue: :default, retry: false

  def perform(message_id)
    message = ByteMessage.find_by(id: message_id)
    return if message.nil?

    conversation = message.byte_conversation
    if conversation&.buddy?
      # The single Buddy delivery path: compaction, state, broadcast, and
      # sleep-on-Mac-failure. Shared with the wake-drain (BuddyWakeWorker).
      Buddy::TurnDispatcher.deliver!(message)
    else
      deliver_plain(message, conversation)
    end
  end

  private

  # claude / bash: plain Mac handoff, reflect success in state + broadcast.
  # No sleep semantics.
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
