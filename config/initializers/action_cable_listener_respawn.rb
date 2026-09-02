require "action_cable/subscription_adapter/redis"

# ActionCable's Redis listener thread is guarded by `@thread ||= Thread.new {...}`,
# and a dead Thread object is still truthy — so once that thread exits, it is never
# replaced for the rest of the process's life. The thread exits whenever the redis
# connection drops and the built-in retry is used up: `reconnect_attempts` defaults
# to 1, so a single failed reconnect ends it permanently.
#
# Nothing about that failure is visible. Broadcasting keeps working, because
# publishing uses a different connection that reconnects on its own. Channels still
# transmit `confirm_subscription`, because `subscribe_to_channel` sends it once
# `subscribed` returns whether or not the deferred `pubsub.subscribe` ever ran. So
# every socket reports itself connected and subscribed while `@subscribed_client` is
# nil, every `when_connected` block queues forever, and no SUBSCRIBE is ever issued.
# Every broadcast is published into a room with nobody in it.
#
# That is what took the site down on 2026-09-02: unattended-upgrades patched
# libgcrypt20 at 06:00:25, needrestart restarted redis-server one second later, and
# every websocket on the site was silently dead until Puma was restarted at 10:21.
# 24.04 ships needrestart in automatic mode, which is why this only started after
# the server move.
#
# Clearing the dead thread lets the existing `||=` build a new one, and resetting the
# attempt counter gives that new thread its retries back — otherwise the counter is
# still spent from the failure that killed the last one. Both happen under
# `@subscription_lock`, which `add_channel` already holds when it calls this.
#
# This recovers on the next subscribe. A process where the listener died and nothing
# new ever subscribes stays dead, so it is not a substitute for the systemd coupling
# in puma_portfolio_production.service.d/20-redis-coupling.conf.
module ActionCableListenerRespawn
  private

  def ensure_listener_running
    if @thread && !@thread.alive?
      @thread = nil
      @reconnect_attempt = 0
    end

    super
  end
end

::ActionCable::SubscriptionAdapter::Redis::Listener.prepend(::ActionCableListenerRespawn)
