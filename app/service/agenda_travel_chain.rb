module AgendaTravelChain
  # Per-day chain detection + metadata persistence for a single user's events.
  #
  # Public surface:
  #   AgendaTravelChain.run_for(user, date)            →  Service.new(user, date).run
  #   AgendaTravelChain.refresh_for(item)              →  re-resolve & re-link for item + day
  #   AgendaTravelChain.force_refresh_for(item)        →  drop fingerprint + refresh_for
  #   AgendaTravelChain.reset_and_recompute_for(record) →  nuke travel metadata + rerun
  #
  # Finding records to pass in (`User.me` is the canonical primary):
  #   ::AgendaItem.find(721)                                       # single event by id
  #   ::User.me.accessible_agenda_items.where(name: "TMS").last    # single event by name
  #   ::AgendaSchedule.find(112)                                   # recurring rule by id
  #   ::User.me.accessible_agendas.find_by(name: "Rockster160")    # full calendar
  #
  # Use `reset_and_recompute_for` when an event/schedule/agenda has gone
  # cross-shape (e.g. a stale top-level legacy mirror after a writer
  # regressed) — it strips both `metadata["travel"]` AND the retired
  # top-level `travel_minutes` / `travel_location` keys before calling
  # the Service so the result is a clean rebuild from Distance Matrix.
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

  # Top-level metadata keys the OLD Jil task 388 wrote alongside the
  # canonical nested `metadata["travel"]`. Cleared whenever we do a full
  # reset so stale mirrors don't survive a recompute. `retire_travel_legacy_mirror`
  # already swept the existing dataset once; this guards against any
  # writers that put them back.
  LEGACY_METADATA_KEYS = %w[travel_minutes travel_location].freeze

  # Nukes every travel-related metadata key from `record` (and, when
  # passed an AgendaSchedule / Agenda, from its dependent rows) and then
  # re-runs the per-day Service across the affected days. Non-travel
  # metadata keys (e.g. dial_config, suite-reminder cache) are preserved.
  #
  # Use to recover an event whose chain metadata has gone stale or
  # cross-shape, or as the per-record building block for a wider sweep.
  def reset_and_recompute_for(record)
    case record
    when ::AgendaItem
      reset_item_metadata!(record)
      refresh_for(record)
    when ::AgendaSchedule
      reset_schedule_metadata!(record)
      items = record.agenda_items.where("start_at >= ?", Time.current).to_a
      items.each { |item| reset_item_metadata!(item) }
      rerun_days_for(record.user, items)
    when ::Agenda
      record.agenda_schedules.find_each { |sched| reset_schedule_metadata!(sched) }
      items = record.agenda_items.where("start_at >= ?", Time.current).to_a
      items.each { |item| reset_item_metadata!(item) }
      rerun_days_for(record.user, items)
    else
      raise ::ArgumentError, "reset_and_recompute_for cannot handle #{record.class.name}"
    end
  end

  def reset_item_metadata!(item)
    new_meta = item.metadata.except("travel", *LEGACY_METADATA_KEYS)
    return if new_meta == item.metadata

    item.update_columns(metadata: new_meta, updated_at: ::Time.current)
    item.metadata.replace(new_meta)
  end

  def reset_schedule_metadata!(schedule)
    new_meta = schedule.metadata.except("travel", *LEGACY_METADATA_KEYS)
    return if new_meta == schedule.metadata

    schedule.update_columns(metadata: new_meta, updated_at: ::Time.current)
    schedule.metadata.replace(new_meta)
  end

  def rerun_days_for(user, items)
    return if items.empty?

    dates = items.each_with_object(::Set.new) { |item, set|
      set << user.timezone { item.start_at.to_date }
    }
    dates.each { |date| run_for(user, date) }
  end
end

require_dependency "agenda_travel_chain/override_parser"
require_dependency "agenda_travel_chain/resolver"
require_dependency "agenda_travel_chain/service"
