module AgendaTravelChain
  # Per-day chain detection + metadata persistence for a single user's events.
  #
  # Public surface:
  #   AgendaTravelChain.run_for(user, date)   →  Service.new(user, date).run
  #   AgendaTravelChain.refresh_for(item)     →  re-resolve & re-link for item + day
  #
  # Everything else (Resolver, Service, OverrideParser) is internal — callers
  # go through the module-level helpers so the implementation can move
  # without rippling.
  module_function

  def run_for(user, date)
    Service.new(user, date).run
  end

  # Variant of `run_for` for the one-shot migration off the legacy task
  # 388 metadata. Uses each event's cached `travel_minutes` for the
  # symmetric home leg in the overlap check; only burns a fresh Google
  # query when overlap actually fires (chain middle's A→B drive).
  def backfill_for(user, date)
    Service.new(user, date, mode: :backfill).run
  end

  # Re-runs the chain compute for a single item's day. NOT a force — the
  # Service's per-event `input_fingerprint` short-circuit keeps repeated
  # calls cheap when nothing material changed. For an explicit force (e.g.
  # a 15-min traffic recheck) use `force_refresh_for` instead.
  def refresh_for(item)
    return unless item

    date = item.user.timezone { item.start_at.to_date }
    Service.new(item.user, date).run
  end

  # Drops the per-event fingerprint so the next Service.run does a real
  # recompute. Use when you genuinely want a fresh Google round-trip.
  def force_refresh_for(item)
    return unless item

    travel = (item.metadata["travel"] || {}).except("input_fingerprint", "location_fingerprint")
    item.update_columns(metadata: item.metadata.merge("travel" => travel), updated_at: Time.current)
    refresh_for(item)
  end
end

require_dependency "agenda_travel_chain/override_parser"
require_dependency "agenda_travel_chain/resolver"
require_dependency "agenda_travel_chain/service"
