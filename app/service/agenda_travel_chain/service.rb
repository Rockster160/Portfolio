module AgendaTravelChain
  # Recomputes the per-day travel chain for one user. Idempotent and
  # short-circuiting: if no candidate event's chain-input has changed since
  # the last sync, no AddressBook calls, no DB writes.
  #
  # Persistence model — all under `metadata["travel"]`, keyed by event:
  #   location_address       (string)  — resolved street address from the
  #                                       Resolver (Places-API formatted for
  #                                       casual names like "Costco", raw
  #                                       text for full addresses). The
  #                                       Distance Matrix call uses this so
  #                                       Google can disambiguate; the user's
  #                                       typed `event.location` stays as-is
  #                                       for display.
  #   location_lat / _lng    (float)   — geocoded coords (sticky until address text changes)
  #   location_fingerprint   (sha)     — invalidates lat/lng resolution
  #   travel_from            (string)  — "Home", a previous event's location,
  #                                       or the event's `from:` override
  #   travel_from_kind       (string)  — "home" | "event" | "override"
  #   travel_seconds         (int)     — drive seconds for the incoming leg
  #   travel_minutes         (int)     — ceil-rounded minutes
  #   chain_predecessor_id   (int|nil)
  #   chain_successor_id     (int|nil)
  #   chain_head_id          (int)     — self if solo head
  #   leave_at               (int)     — epoch: when the user should start driving for this leg
  #   post_travel_to         (string)  — `to:` override text — where the user is
  #                                       headed AFTER the event ends (only
  #                                       written when the override is set)
  #   post_travel_seconds    (int)     — drive seconds for the outgoing leg
  #                                       (event.location → post_travel_to)
  #   post_travel_minutes    (int)     — ceil-rounded minutes for the outgoing leg
  #   post_arrive_at         (int)     — epoch: end_at + post_travel_seconds
  #                                       (when the user arrives at post_travel_to)
  #   overrides              (hash)    — { nonav, notme, before, after, from, to }
  #   input_fingerprint      (sha)     — full chain-input hash; skip recompute when matched
  class Service
    FROM_KIND_HOME = "home".freeze
    FROM_KIND_EVENT = "event".freeze
    FROM_KIND_OVERRIDE = "override".freeze

    # Agenda-name fragments (case-insensitive) for calendars the user has
    # explicitly opted OUT of travel calculations. Mirrors the original
    # task 388 check (`agendaName.contains?("oneclaimsolution")`). Add
    # entries here as the user opts more calendars out — or migrate to a
    # per-agenda flag later if the list grows.
    EXCLUDED_AGENDA_FRAGMENTS = %w[oneclaimsolution].freeze

    def initialize(user, date, mode: :normal)
      @user = user
      @date = date
      @mode = mode
      @resolver = Resolver.new(user)
      @overrides_cache = {}
      # Agendas whose items had a metadata write this run. Collected so
      # we can broadcast a single fan-out at the end — `update_columns`
      # in `apply_metadata!` bypasses after_commit, which means clients
      # never see chain recomputes live (they only catch up on a hard
      # reload or focus refresh) unless we explicitly notify here. This
      # is what caused a cross-day move to leave a stale `chain_prev_end_at`
      # visible on screen until the user manually reloaded.
      @touched_agendas = {}
    end

    def run
      candidates = collect_candidates
      clear_dropouts(candidates)

      if candidates.any?
        # Backfill skips per-event geocoding — those events were created
        # before phase 1 and don't have lat/lng cached, and per-event nav
        # uses the raw event.location string anyway. Saves a Google
        # round-trip per event during the migration sweep.
        ensure_resolved_all(candidates) unless backfill?
        links = link_pairs(candidates)
        head_for = compute_head_map(candidates, links)

        # Now write metadata. The fingerprint short-circuit is evaluated PER
        # event during write — events whose effective inputs match their stored
        # fingerprint just skip the write entirely.
        candidates.each_with_index do |evt, idx|
          prev = idx.positive? ? candidates[idx - 1] : nil
          persist_event(evt, prev, links, head_for, candidates)
        end
      end

      broadcast_touched_agendas!
    end

    private

    # ----- candidate selection -------------------------------------------------

    def collect_candidates
      scope = @user.accessible_agenda_items
        .where(kind: ::AgendaItem.kinds[:event])
        .where(all_day: false)
        .where(start_at: day_range)
        .where.not(location: [nil, ""])
        .includes(:agenda)
        .order(:start_at, :id)
      scope.to_a.reject { |evt|
        overrides_for(evt)[:nonav] ||
          excluded_agenda?(evt) ||
          ::AddressBook.non_travelable?(evt.location)
      }
    end

    # An event whose host agenda is on the user's opt-out list — e.g.
    # the OCS work calendar where events are virtual / on-site by default
    # and travel triggers would be noise.
    def excluded_agenda?(evt)
      name = evt.agenda&.name.to_s.downcase
      EXCLUDED_AGENDA_FRAGMENTS.any? { |frag| name.include?(frag) }
    end

    def day_range
      @user.timezone {
        zone = Time.zone
        start = zone.local(@date.year, @date.month, @date.day)
        start..(start + 1.day)
      }
    end

    def overrides_for(evt)
      @overrides_cache[evt.id] ||= OverrideParser.parse(evt.notes)
    end

    # Events whose previous run wrote `metadata["travel"]` but which no longer
    # qualify (location cleared, nonav added, all_day toggled, destroyed)
    # need their stored chain pointers cleared so the calendar/triggers stop
    # treating them as chain participants.
    #
    # Scoped to the candidate base (kind=event, all_day=false, has location)
    # — non-event items (tasks, triggers) can legitimately carry travel
    # metadata from Jil's task 388 and must not be stripped here.
    def clear_dropouts(current)
      current_ids = current.map(&:id).to_set
      @user.accessible_agenda_items
        .where(kind: ::AgendaItem.kinds[:event])
        .where(all_day: false)
        .where(start_at: day_range)
        .where("metadata ? 'travel'")
        .find_each do |evt|
          next if current_ids.include?(evt.id)
          next if evt.metadata["travel"].blank?

          write_metadata(evt, nil)
        end
    end

    # ----- geocode resolution (sticky) ----------------------------------------

    def ensure_resolved_all(candidates)
      candidates.each { |evt| ensure_resolved(evt) }
    end

    def ensure_resolved(evt)
      fp = location_fingerprint(evt)
      return if evt.metadata.dig("travel", "location_fingerprint") == fp

      res = @resolver.resolve_location(evt.location)
      return unless res

      merge_travel_metadata(evt,
        "location_address" => res[:address],
        "location_lat"     => res[:lat],
        "location_lng"     => res[:lng],
        "location_fingerprint" => fp,
      )
    end

    def location_fingerprint(evt)
      ::Digest::SHA256.hexdigest(evt.location.to_s)
    end

    # ----- chain linking ------------------------------------------------------

    def link_pairs(events)
      events.each_cons(2).each_with_object({}) { |(a, b), links|
        next unless chain?(a, b)

        (links[a.id] ||= {})[:successor_id] = b.id
        (links[b.id] ||= {})[:predecessor_id] = a.id
      }
    end

    # Overlap rule: A chains to B when "go home, then leave for B from home"
    # wouldn't actually have time to happen. before/after overrides shift
    # the endpoints we compute against.
    #
    # In `backfill` mode the home-leg seconds come straight from each
    # event's cached `travel_minutes` (the OLD task 388 wrote it as a
    # Home→event distance, and we assume travel is symmetric — burning a
    # fresh Google query just to confirm that on every event would torch
    # the Distance Matrix budget for no real gain). The fresh A→B drive
    # only fires AFTER chain is confirmed, inside persist_event.
    def chain?(a, b)
      # `from:` on B asserts an explicit start that isn't A's location — chain
      # detection no longer applies because B isn't rolling forward from A.
      return false if overrides_for(b)[:from].present?

      a_out = outgoing_last_location(a)
      b_in  = incoming_first_location(b)
      return false if a_out.blank? || b_in.blank?

      a_to = overrides_for(a)[:to].presence
      if a_to
        # A is committed to `to:` after the event. The via-point is the
        # `to:` location instead of home — chain when B's required leave
        # time wouldn't accommodate the user arriving at to: and driving
        # onward to B.
        a_via = @resolver.travel_seconds(a_out, a_to, at: a.end_at)
        via_b = @resolver.travel_seconds(a_to,   b_in, at: b.start_at)
        return false if a_via.nil? || via_b.nil?

        leave_for_b_via = b.start_at.to_i - (b.arrive_early_minutes.to_i * 60) - via_b
        a.end_at.to_i + a_via > leave_for_b_via
      else
        return false if home_text.blank?

        a_home = chain_home_seconds(a, a_out, a.end_at)
        home_b = chain_home_seconds(b, b_in,  b.start_at)
        return false if a_home.nil? || home_b.nil?

        leave_for_b_from_home = b.start_at.to_i - (b.arrive_early_minutes.to_i * 60) - home_b
        a.end_at.to_i + a_home > leave_for_b_from_home
      end
    end

    def chain_home_seconds(evt, other_loc, at)
      if backfill?
        cached = cached_travel_seconds(evt)
        return cached if cached&.positive?
      end
      @resolver.travel_seconds(other_loc, home_text, at: at)
    end

    def cached_travel_seconds(evt)
      nested = evt.metadata.dig("travel", "travel_seconds")
      nested.to_i.positive? ? nested.to_i : nil
    end

    def backfill?
      @mode == :backfill
    end

    # `to:` declares an explicit POST-event destination; treat it as the
    # final outgoing endpoint when present, otherwise fall back to the last
    # `after:` waypoint (legacy behavior) and finally the event's location.
    def outgoing_last_location(evt)
      overrides = overrides_for(evt)
      overrides[:to].presence ||
        overrides[:after].last.presence ||
        resolved_location(evt) ||
        evt.location.to_s
    end

    def incoming_first_location(evt)
      overrides = overrides_for(evt)
      overrides[:before].first.presence ||
        resolved_location(evt) ||
        evt.location.to_s
    end

    # Loose equality for two location strings — strip + downcase. Lets a
    # `from:Greens Lake Campground` on an event ALREADY at "Greens Lake
    # Campground" short-circuit the drive to 0 without a Google round-trip
    # (and without depending on Distance Matrix's behavior for same-point
    # queries, which can return small non-zero distances).
    def same_place?(a, b)
      return false if a.blank? || b.blank?

      a.to_s.strip.casecmp(b.to_s.strip).zero?
    end

    # Resolved street address stashed by `ensure_resolved` — prefer it over
    # the raw location text when feeding the Distance Matrix call, since
    # Google can't disambiguate casual names ("Texas Roadhouse" → which
    # branch?). Stays as the user-typed value for display (`travel_from`,
    # FE labels) — only the API-bound path uses the resolved version.
    def resolved_location(evt)
      evt.metadata.dig("travel", "location_address").presence
    end

    def home_text
      return @home_text if defined?(@home_text)

      @home_text = @resolver.home&.street.to_s
    end

    def compute_head_map(events, links)
      head = {}
      events.each do |evt|
        prev_id = links.dig(evt.id, :predecessor_id)
        head[evt.id] = prev_id ? head[prev_id] : evt.id
      end
      head
    end

    # ----- persistence --------------------------------------------------------

    def persist_event(evt, prev, links, head_for, all_events)
      pred_id = links.dig(evt.id, :predecessor_id)
      succ_id = links.dig(evt.id, :successor_id)

      pred = pred_id ? prev : nil # candidates are ordered; pred is always prev when linked
      override_from = overrides_for(evt)[:from].presence
      from_text, from_kind = (
        if override_from
          [override_from, FROM_KIND_OVERRIDE]
        elsif pred
          [pred.location.to_s, FROM_KIND_EVENT]
        else
          [home_text, FROM_KIND_HOME]
        end
      )
      from_for_drive = override_from || (pred ? outgoing_last_location(pred) : home_text)

      incoming_first = incoming_first_location(evt)
      # Backfill optimisation: solo / chain-head events leave FROM Home,
      # which is exactly what the cached `travel_minutes` already
      # represents. Use it directly, skip Google. Chain middles / tails
      # come from a previous event's location — that IS the new Google
      # round-trip we're willing to pay for once the chain has been
      # confirmed. `from:` is an explicit start we have no cached drive
      # for, so always go fetch a fresh one.
      drive_secs = (
        if same_place?(from_for_drive, incoming_first)
          # User explicitly says they're already at the event's start point
          # (`from:` matches the event location, or chained predecessor's
          # outgoing endpoint already equals it). Skip the Google round-trip
          # and represent it as a 0-minute leg.
          0
        elsif backfill? && pred.nil? && override_from.nil?
          cached_travel_seconds(evt)
        else
          @resolver.travel_seconds(from_for_drive, incoming_first, at: evt.start_at)
        end
      )
      drive_mins = drive_secs && (drive_secs / 60.0).ceil
      leave_at = drive_secs && (evt.start_at.to_i - (evt.arrive_early_minutes.to_i * 60) - drive_secs)

      post_to = overrides_for(evt)[:to].presence
      post_drive_secs = (
        if post_to
          outgoing = outgoing_last_location(evt)
          same_place?(evt.location.to_s, outgoing) ? 0 : @resolver.travel_seconds(evt.location.to_s, outgoing, at: evt.end_at)
        end
      )
      post_drive_mins = post_drive_secs && (post_drive_secs / 60.0).ceil
      post_arrive_at = post_drive_secs && (evt.end_at.to_i + post_drive_secs)

      travel = {
        "location_address"     => evt.metadata.dig("travel", "location_address"),
        "location_lat"         => evt.metadata.dig("travel", "location_lat"),
        "location_lng"         => evt.metadata.dig("travel", "location_lng"),
        "location_fingerprint" => evt.metadata.dig("travel", "location_fingerprint"),
        "travel_from"          => from_text,
        "travel_from_kind"     => from_kind,
        "travel_seconds"       => drive_secs,
        "travel_minutes"       => drive_mins,
        "chain_predecessor_id" => pred_id,
        "chain_successor_id"   => succ_id,
        "chain_head_id"        => head_for[evt.id],
        # Predecessor's end_at gives the calendar the upper bound to extend
        # the travel band to, since chain bands fill the GAP between two
        # events visually rather than just rendering the drive minutes.
        "chain_prev_end_at"    => (pred&.end_at&.to_i if pred),
        "leave_at"             => leave_at,
        "post_travel_to"       => post_to,
        "post_travel_seconds"  => post_drive_secs,
        "post_travel_minutes"  => post_drive_mins,
        "post_arrive_at"       => post_arrive_at,
        "overrides"            => overrides_for(evt).transform_keys(&:to_s),
      }
      fp = input_fingerprint(evt, all_events, travel)
      stored_fp = evt.metadata.dig("travel", "input_fingerprint")
      return if stored_fp.present? && stored_fp == fp

      travel["input_fingerprint"] = fp
      write_metadata(evt, travel.compact)
    end

    def input_fingerprint(evt, _all_events, travel)
      payload = {
        loc:      evt.location.to_s,
        start:    evt.start_at.to_i,
        end:      evt.end_at&.to_i,
        early:    evt.arrive_early_minutes.to_i,
        overrides: travel["overrides"],
        chain:    [travel["chain_predecessor_id"], travel["chain_successor_id"]],
        from:     travel["travel_from"],
        drive:    travel["travel_seconds"],
        post:     [travel["post_travel_to"], travel["post_travel_seconds"]],
        home:     home_text,
      }
      ::Digest::SHA256.hexdigest(payload.to_json)
    end

    # ----- metadata write helpers ---------------------------------------------

    # Bypasses the AgendaItem after_commit (per metadata_only_change?) by
    # using update_columns. Avoids the re-entry that would otherwise have
    # this worker fire itself recursively.
    def merge_travel_metadata(evt, **changes)
      current = (evt.metadata["travel"] || {}).merge(changes.stringify_keys)
      new_meta = evt.metadata.merge("travel" => current)
      apply_metadata!(evt, new_meta)
      propagate_to_schedule(evt, current)
    end

    # Pass `nil` for `travel_hash` to fully clear the travel key for events
    # that have dropped out of the chain.
    def write_metadata(evt, travel_hash)
      new_meta = evt.metadata.except("travel")
      new_meta = new_meta.merge("travel" => travel_hash) if travel_hash.present?
      apply_metadata!(evt, new_meta)
      propagate_to_schedule(evt, travel_hash) if travel_hash.present?
    end

    # Mirror the static (non-chain, non-time-anchored) slice of an item's
    # travel hash onto its parent schedule. Phantoms inherit from the
    # schedule (recurrence.js builds them by cloning `schedule.metadata`),
    # so without this every future occurrence renders a 0-minute band.
    # Chain pointers and `leave_at` / `post_arrive_at` are intentionally
    # excluded — they're computed per-occurrence and meaningless on the
    # schedule level.
    SCHEDULE_TRAVEL_KEYS = %w[
      location_address location_lat location_lng location_fingerprint
      travel_from travel_from_kind
      travel_seconds travel_minutes
      post_travel_to post_travel_seconds post_travel_minutes
    ].freeze
    private_constant :SCHEDULE_TRAVEL_KEYS

    def propagate_to_schedule(evt, travel_hash)
      schedule = evt.agenda_schedule
      return unless schedule

      slice = travel_hash.slice(*SCHEDULE_TRAVEL_KEYS).compact
      return if slice.empty?

      current_sched_travel = schedule.metadata["travel"] || {}
      next_sched_travel = current_sched_travel.merge(slice)
      return if current_sched_travel == next_sched_travel

      new_meta = schedule.metadata.merge("travel" => next_sched_travel)
      schedule.update_columns(metadata: new_meta, updated_at: Time.current)
    end

    def apply_metadata!(evt, new_meta)
      evt.update_columns(metadata: new_meta, updated_at: Time.current)
      evt.metadata.replace(new_meta)
      # Stage the agenda for the end-of-run broadcast. `update_columns`
      # bypassed the after_commit broadcast path, so without this clients
      # would never see the chain recompute land — a cross-day move's
      # stale `chain_prev_end_at` would stick on screen until a hard
      # reload (and even that only worked if the worker's write actually
      # landed before the user reloaded).
      agenda = evt.agenda
      @touched_agendas[agenda.id] = agenda if agenda
    end

    def broadcast_touched_agendas!
      return if @touched_agendas.empty?

      ::Agenda.broadcast_changes!(@touched_agendas.values)
    end
  end
end
