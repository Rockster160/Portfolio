module AgendaTravelChain
  # Per-day chain detection + metadata persistence for a single user's events.
  #
  # Public surface:
  #   AgendaTravelChain.run_for(user, date)   →  Service.new(user, date).run
  #   AgendaTravelChain.trip_waypoints(item)  →  ordered Array<Hash> waypoint plan
  #   AgendaTravelChain.refresh_for(item)     →  forces re-resolve & re-link for item + day
  #
  # Everything else (Resolver, Service, OverrideParser) is internal — callers
  # go through the module-level helpers so the implementation can move
  # without rippling.
  module_function

  def run_for(user, date)
    Service.new(user, date).run
  end

  # Returns the full ordered trip the chain head's prepare task would send to
  # the car. Each entry: { name:, address:, lat:, lng: }. Home is appended
  # as the final waypoint when the trip doesn't already end there.
  def trip_waypoints(item)
    return [] if item.blank?

    head_id = item.metadata.dig("travel", "chain_head_id") || item.id
    head = ::AgendaItem.locate_for_user(head_id, item.user) || item
    TripBuilder.new(head).waypoints
  end

  # Force re-resolve and re-chain for a single item's day. Used by
  # `Custom.refreshTravelTime` (the user's 15-min-before bump task). The
  # caller (Jil-side) decides WHEN this happens — we just do the work.
  def refresh_for(item)
    return unless item

    item.update_column(:metadata, item.metadata.merge("travel" => (item.metadata["travel"] || {}).except("input_fingerprint", "location_fingerprint")))
    date = item.user.timezone { item.start_at.to_date }
    Service.new(item.user, date).run
  end
end

require_dependency "agenda_travel_chain/override_parser"
require_dependency "agenda_travel_chain/resolver"
require_dependency "agenda_travel_chain/service"
require_dependency "agenda_travel_chain/trip_builder"
