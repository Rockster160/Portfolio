# Collapses repeated view-refreshes inside one Jil execution chain down to one.
#
# A single task often touches several schedules in a row — a nap press arms the
# wake timer, arms the take-cover alert, stands down the stale timers and books
# the next nap and potty. Each schedule write broadcasts a `:schedule` trigger,
# which recomputes and rebroadcasts the whole "Upcoming" agenda; done inline,
# that is one ~2s recompute PER write, run serially, and it is what made the
# board take ten-plus seconds to show she was napping.
#
# While a chain is running, a refresh is REGISTERED here instead of run, keyed by
# its payload so identical ones collapse, and the whole set is flushed ONCE when
# the outermost execution finishes. The flush is deterministic (end of the unit
# of work, not a timer) and runs from `execute_all`'s `ensure`, so it fires even
# when the chain raised — the view is always recomputed from the FINAL state and
# never left stale. Outside an execution (a controller, the websocket's own
# refresh) nothing is active and refreshes run inline exactly as before.
module Jil::RefreshCoalescer
  module_function

  KEY = :jil_refresh_coalescer

  def active?
    !Thread.current[KEY].nil?
  end

  # Run `block` as one coalescing unit. The OUTERMOST caller owns the buffer and
  # the flush; a nested call (a triggered task reached through this one) just
  # yields, so every refresh raised anywhere in the chain lands in the one buffer
  # and is flushed here. Ownership is cleared in `ensure` so a reused Sidekiq
  # thread never carries a buffer into the next job.
  def coalesce
    return yield if active?

    Thread.current[KEY] = {}
    begin
      yield
    ensure
      pending = Thread.current[KEY]
      Thread.current[KEY] = nil
      flush(pending)
    end
  end

  # Register a refresh to run once at end-of-unit, deduped by `key`. Only call it
  # when `active?` — a caller with no unit running runs its refresh inline instead.
  # The last registration under a key wins; since the refreshes under one key are
  # identical recomputes, that is simply "run it once".
  def register(key, &run)
    store = Thread.current[KEY]
    store[key] = run if store
  end

  def flush(pending)
    return if pending.blank?

    pending.each_value { |run| run_safely(run) }
  end

  def run_safely(run)
    run.call
  rescue StandardError => e
    Rails.logger.error("[Jil::RefreshCoalescer] flush failed: #{e.class}: #{e.message}")
  end
end
