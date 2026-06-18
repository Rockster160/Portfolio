module AgendaTravelChain
  # Recomputes the per-day travel chain for one user. Idempotent and
  # short-circuiting: if no candidate event's chain-input has changed since
  # the last sync, no AddressBook calls, no DB writes.
  #
  # Persistence model — all under `metadata["travel"]`, keyed by event:
  #   location_address       (string)  — original event.location text
  #   location_lat / _lng    (float)   — geocoded coords (sticky until address text changes)
  #   location_fingerprint   (sha)     — invalidates lat/lng resolution
  #   travel_from            (string)  — "Home" or a previous event's location
  #   travel_from_kind       (string)  — "home" | "event"
  #   travel_seconds         (int)     — drive seconds for the incoming leg
  #   travel_minutes         (int)     — ceil-rounded minutes (mirrored to legacy top-level)
  #   chain_predecessor_id   (int|nil)
  #   chain_successor_id     (int|nil)
  #   chain_head_id          (int)     — self if solo head
  #   leave_at               (int)     — epoch: when the user should start driving for this leg
  #   overrides              (hash)    — { nonav, notme, before, after }
  #   input_fingerprint      (sha)     — full chain-input hash; skip recompute when matched
  class Service
    FROM_KIND_HOME = "home".freeze
    FROM_KIND_EVENT = "event".freeze

    def initialize(user, date)
      @user = user
      @date = date
      @resolver = Resolver.new(user)
      @overrides_cache = {}
    end

    def run
      candidates = collect_candidates
      clear_dropouts(candidates)

      return if candidates.empty?

      ensure_resolved_all(candidates)
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

    private

    # ----- candidate selection -------------------------------------------------

    def collect_candidates
      scope = @user.accessible_agenda_items
        .where(kind: ::AgendaItem.kinds[:event])
        .where(all_day: false)
        .where(start_at: day_range)
        .where.not(location: [nil, ""])
        .order(:start_at, :id)
      scope.to_a.reject { |evt| overrides_for(evt)[:nonav] }
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
    # qualify (location cleared, nonav added, all_day toggled, kind flipped,
    # destroyed) need their stored chain pointers cleared so the calendar/
    # triggers stop treating them as chain participants.
    def clear_dropouts(current)
      current_ids = current.map(&:id).to_set
      @user.accessible_agenda_items
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
    # wouldn't actually have time to happen. before/after overrides shift the
    # endpoints we compute against.
    def chain?(a, b)
      a_out = outgoing_last_location(a)
      b_in  = incoming_first_location(b)
      return false if a_out.blank? || b_in.blank?
      return false if home_text.blank?

      a_home = @resolver.travel_seconds(a_out, home_text, at: a.end_at)
      home_b = @resolver.travel_seconds(home_text, b_in,  at: b.start_at)
      return false if a_home.nil? || home_b.nil?

      leave_for_b_from_home = b.start_at.to_i - (b.arrive_early_minutes.to_i * 60) - home_b
      a.end_at.to_i + a_home > leave_for_b_from_home
    end

    def outgoing_last_location(evt)
      overrides_for(evt)[:after].last.presence || evt.location.to_s
    end

    def incoming_first_location(evt)
      overrides_for(evt)[:before].first.presence || evt.location.to_s
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
      from_text, from_kind = pred ? [pred.location.to_s, FROM_KIND_EVENT] : [home_text, FROM_KIND_HOME]
      from_for_drive = pred ? outgoing_last_location(pred) : home_text

      incoming_first = incoming_first_location(evt)
      drive_secs = @resolver.travel_seconds(from_for_drive, incoming_first, at: evt.start_at)
      drive_mins = drive_secs && (drive_secs / 60.0).ceil
      leave_at = drive_secs && (evt.start_at.to_i - (evt.arrive_early_minutes.to_i * 60) - drive_secs)

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
        "leave_at"             => leave_at,
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
      mirror_legacy_keys!(new_meta, current)
      apply_metadata!(evt, new_meta)
    end

    # Pass `nil` for `travel_hash` to fully clear the travel key (and its
    # mirrored legacy fields) for events that have dropped out of the chain.
    def write_metadata(evt, travel_hash)
      new_meta = evt.metadata.except("travel")
      new_meta = new_meta.merge("travel" => travel_hash) if travel_hash.present?
      mirror_legacy_keys!(new_meta, travel_hash || {})
      apply_metadata!(evt, new_meta)
    end

    def apply_metadata!(evt, new_meta)
      evt.update_columns(metadata: new_meta, updated_at: Time.current)
      evt.metadata.replace(new_meta)
    end

    # Keep `metadata.travel_minutes` populated at the top level — the
    # calendar/seed-hydrator/JS still read from there. Phase 2 migrates them
    # to the nested key.
    def mirror_legacy_keys!(meta, travel)
      if travel.empty?
        meta.delete("travel_minutes")
        meta.delete("travel_location")
        return
      end
      meta["travel_minutes"]  = travel["travel_minutes"]
      meta["travel_location"] = travel["travel_from"]
    end
  end
end
