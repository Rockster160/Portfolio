# Ephemeral, connection-scoped "watch a trigger from the terminal" registry.
#
# `bin/watch_trigger <listener>` subscribes to MonitorChannel and asks the
# server to notify it the next time a trigger matching that listener fires -
# written in the SAME listener syntax the 70-odd Jil tasks use and matched by
# the same ::Jil::ListenerMatch code, so `hass-sensor:location:doorbell` means
# exactly what it means in a task.
#
# Unlike a BuddyWatch this is NOT persisted: it lives only as long as the
# terminal stays connected. Registrations sit in Rails.cache (Redis in prod, so
# the Sidekiq process that fires the trigger and the cable process the terminal
# is attached to share one registry) and each carries an `expires_at`. The
# terminal heartbeats to keep its lease alive; a dropped connection simply lets
# the lease lapse and the watch falls out on the next prune.
module TerminalWatch
  module_function

  # One global key, read once per trigger - the same cost profile as
  # Buddy::WatchMatcher's scope cache. Terminal watches are rare and
  # short-lived, so the whole registry is tiny; a single key sidesteps having
  # to enumerate per-user keys just to know which scopes anything is watching.
  CACHE_KEY = "terminal_watch:registry".freeze
  # The key's own TTL is a backstop against a leaked registry; individual
  # leases (LEASE) are what actually expire a watch between heartbeats.
  TTL = 10.minutes
  LEASE = 60 # seconds a registration survives without a heartbeat

  def register(user, watch_id, listener)
    return if user.nil? || watch_id.blank? || listener.blank?

    scope = ::Jil::ListenerMatch.scope_of(listener)
    update { |reg|
      reg[key(user, watch_id)] = {
        user_id:    user.id,
        watch_id:   watch_id.to_s,
        listener:   listener.to_s,
        scope:      scope,
        expires_at: lease_until,
      }
    }
    scope
  end

  def heartbeat(user, watch_id)
    return if user.nil? || watch_id.blank?

    update { |reg|
      entry = reg[key(user, watch_id)]
      reg[key(user, watch_id)] = entry.merge(expires_at: lease_until) if entry
    }
  end

  def unregister(user, watch_id)
    return if user.nil? || watch_id.blank?

    update { |reg| reg.delete(key(user, watch_id)) }
  end

  # Called from Jil::Executor.trigger for EVERY trigger. One cache read, then
  # bail unless a live terminal is actually watching this user + scope.
  def dispatch(user, scope, trigger_data)
    return if user.nil?

    reg = registry
    return if reg.empty?

    scope = scope.to_s
    now = ::Time.current.to_i
    live = reg.values.select { |w|
      w[:user_id] == user.id && w[:scope] == scope && w[:expires_at].to_i > now
    }
    return if live.empty?

    live.each { |watch|
      next unless ::Jil::ListenerMatch.call(watch[:listener], scope, trigger_data)

      broadcast!(user, watch, scope, trigger_data)
    }
  rescue StandardError => e
    # A terminal watch must never take down the trigger it rides on.
    Rails.logger.warn("[TerminalWatch] dispatch failed: #{e.class}: #{e.message}")
  end

  def broadcast!(user, watch, scope, trigger_data)
    ::MonitorChannel.broadcast_to(user, {
      id:        :"terminal-watch",
      type:      :hit,
      watch_id:  watch[:watch_id],
      listener:  watch[:listener],
      scope:     scope,
      timestamp: ::Time.current.to_i,
      data:      preview(trigger_data),
    })
  end

  # A compact, JSON-safe glimpse of the payload for the terminal to print.
  # Triggers arrive as a Hash (Jil-built) or as the record itself (model
  # sourced, carrying derived fields in execution_attrs) - flatten either to a
  # small stringified hash, matching how Buddy::WatchMatcher normalizes.
  def preview(trigger_data)
    hash = (
      if trigger_data.is_a?(::Hash)
        trigger_data
      elsif trigger_data.respond_to?(:execution_attrs)
        base = trigger_data.respond_to?(:attributes) ? trigger_data.attributes : {}
        base.merge(trigger_data.execution_attrs || {})
      else
        {}
      end
    )
    hash.to_h.first(20).to_h.deep_stringify_keys.transform_values { |v|
      v.is_a?(::String) ? v.first(200) : v
    }
  rescue StandardError
    {}
  end

  def registry
    Rails.cache.read(CACHE_KEY) || {}
  end

  # Read-modify-write of the single registry key. Concurrent writers can race
  # here, but terminal watches are rare and the heartbeat re-adds within LEASE,
  # so a clobbered entry self-heals within a heartbeat interval. Every write
  # also prunes expired leases so a dropped connection can't leak forever.
  def update
    reg = registry
    yield(reg)
    now = ::Time.current.to_i
    reg.reject! { |_k, w| w[:expires_at].to_i <= now }
    Rails.cache.write(CACHE_KEY, reg, expires_in: TTL)
  end

  def key(user, watch_id)
    "#{user.id}:#{watch_id}"
  end

  def lease_until
    ::Time.current.to_i + LEASE
  end
end
