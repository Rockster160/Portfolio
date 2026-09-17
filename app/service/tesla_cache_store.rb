# Two raw source-of-truth caches + the formatted `:car_data` view that every
# reader (dashboard, Jarvis, Jil tasks, tire check) consumes.
#
#   :tesla_telemetry → fleet-telemetry pushes (raw, deep-merged + section_ts/field_ts)
#   :tesla_endpoint  → vehicle_data HTTP polls (raw, last response)
#   :car_data        → small, flat, normalized projection of the above
#
# The raw caches are kept for debugging. `car_data` is the source of truth
# for everything human-facing — small enough to read at a glance, with each
# field normalized (units converted, enum strings → bools, etc.) and per-
# section timestamps so readers can reason about freshness.
class TeslaCacheStore
  HISTORY_LIMIT = 10
  TELEMETRY_KEY = :tesla_telemetry
  ENDPOINT_KEY  = :tesla_endpoint
  CAR_DATA_KEY  = :car_data

  INVALID_SENTINEL = "<invalid>".freeze
  TRANSIENT_CHARGE_STATES = ["ClearFaults"].freeze
  BAR_TO_PSI = 14.504

  # Telemetry fields where Tesla actively pushes `<invalid>` on sensor-offline
  # (key-out) — we rewrite to a concrete default so the deep_merge overwrites
  # the last valid value instead of retaining it forever. Empirically verified
  # from fleet-telemetry captures: VehicleSpeed and Gear both push `<invalid>`;
  # ChargeState does not (it either stops updating or lingers as "Idle"), so
  # the phantom-bolt fix has to live in the endpoint-preference logic inside
  # compose_charging instead.
  INVALID_DEFAULTS = {
    VehicleSpeed: 0,
    Gear:         "ShiftStateP",
  }.freeze

  # Which telemetry field belongs to which car_data section. Used both to
  # apply values during compose AND to stamp the section's :ts whenever a
  # telemetry record touches any of its fields.
  TELEMETRY_SECTIONS = {
    location: %i[Location GpsHeading GpsState],
    battery:  %i[],
    charging: %i[ChargeState],
    drive:    %i[VehicleSpeed Gear],
    trip:     %i[MilesToArrival MinutesToArrival OriginLocation DestinationLocation RouteLine],
    climate:  %i[HvacPower InsideTemp OutsideTemp],
    doors:    %i[DoorState Locked],
    windows:  %i[FdWindow FpWindow RdWindow RpWindow],
    tires:    %i[TpmsPressureFl TpmsPressureFr TpmsPressureRl TpmsPressureRr],
    odometer: %i[Odometer],
    meta:     %i[VehicleName Vin],
  }.freeze

  # How long a route stays true after the last thing said about it.
  #
  # Neither source can be asked "is nav on right now". The endpoint poll clears
  # active_route_miles/minutes_to_arrival when nav ends but leaves the
  # destination coords behind; telemetry just stops pushing, and its
  # deep-merged DestinationLocation/MilesToArrival keep a finished drive
  # forever. Age is the only honest signal either one gives.
  #
  # Telemetry restates a loaded route every minute (RouteLine, and Tesla floors
  # a requested interval at 60s — see TeslaService.fields), so three minutes is
  # two missed pushes: long enough that a dropped record doesn't blink a live
  # route off the dashboard, short enough that a finished drive stops being
  # reported as one while the driver is still walking inside.
  TRIP_EVIDENCE_WINDOW_MS = 3 * 60 * 1000

  # Position keys are shared by doors and windows so a "driver_front" door
  # and "driver_front" window read the same way. Matches the snake_case form
  # of Tesla's own DoorState keys (DriverFront → driver_front).
  WINDOW_KEYS = {
    driver_front:    :FdWindow,
    passenger_front: :FpWindow,
    driver_rear:     :RdWindow,
    passenger_rear:  :RpWindow,
  }.freeze

  DOOR_KEYS = {
    driver_front:    :DriverFront,
    passenger_front: :PassengerFront,
    driver_rear:     :DriverRear,
    passenger_rear:  :PassengerRear,
    frunk:           :TrunkFront,
    trunk:           :TrunkRear,
  }.freeze

  # Endpoint-poll car_data uses these short keys for the same positions
  # (df=driver front, ft=frunk, rt=trunk). Used to fall back to the poll
  # snapshot when telemetry hasn't sent DoorState yet.
  DOOR_ENDPOINT_FALLBACK = {
    driver_front:    :df,
    passenger_front: :pf,
    driver_rear:     :dr,
    passenger_rear:  :pr,
    frunk:           :ft,
    trunk:           :rt,
  }.freeze

  TIRE_TEL_KEYS = {
    fl: :TpmsPressureFl, fr: :TpmsPressureFr,
    rl: :TpmsPressureRl, rr: :TpmsPressureRr,
  }.freeze

  # Tesla stamps each state section of a vehicle_data response itself. Those
  # stamps are the only endpoint timestamps that describe the DATA — the poll's
  # own wall-clock stamp describes the REQUEST, and advances on every hourly
  # poll whether or not the car said anything new.
  ENDPOINT_TS_PATHS = [
    %i[charge_state timestamp],
    %i[climate_state timestamp],
    %i[drive_state timestamp],
    %i[vehicle_state timestamp],
  ].freeze

  class << self
    def record_telemetry(payload)
      store_telemetry(payload)
      refresh_car_data!
    end

    def record_endpoint(payload)
      store_endpoint(payload)
      refresh_car_data!
    end

    def telemetry_cache = User.me.caches.get(TELEMETRY_KEY) || {}
    def endpoint_cache  = User.me.caches.get(ENDPOINT_KEY)  || {}
    def car_data        = User.me.caches.get(CAR_DATA_KEY)  || {}

    def refresh_car_data!
      composed = compose(endpoint_cache, telemetry_cache)
      User.me.caches.set(CAR_DATA_KEY, composed)
      composed
    end

    private

    # Deep-merge incoming telemetry into `current`, dropping `<invalid>` and
    # noise. Track per-section last-touched timestamps in `section_ts` so the
    # composer can stamp each section's :ts without re-scanning history.
    def store_telemetry(payload)
      raw      = payload.to_h.deep_symbolize_keys
      data     = raw[:data].is_a?(Hash) ? raw[:data] : raw
      # History preserves the raw record verbatim — apply the invalid-default
      # rewrite only to what flows into current/cleaned.
      defaulted = apply_invalid_defaults(data)
      cleaned  = strip_invalid(defaulted) || {}
      stamp    = now_ms
      existing = User.me.caches.get(TELEMETRY_KEY) || {}
      current  = (existing[:current] || {}).deep_merge(cleaned)
      section_ts = (existing[:section_ts] || {}).symbolize_keys
      sections_in_record(cleaned).each { |s| section_ts[s] = stamp }
      # Per-FIELD stamps too: a section stamp can't answer "how old is this one
      # field", because any field in the section refreshes it. Gear needs the
      # finer grain — see compose_drive.
      field_ts = (existing[:field_ts] || {}).symbolize_keys
      cleaned.each_key { |k| field_ts[k.to_sym] = stamp }
      entry    = { timestamp: stamp, data: data }
      history  = [entry, *(existing[:history] || [])].first(HISTORY_LIMIT)

      User.me.caches.set(TELEMETRY_KEY, {
        current:    current,
        section_ts: section_ts,
        field_ts:   field_ts,
        history:    history,
      })
    end

    # The endpoint poll is a full snapshot; replace rather than merge.
    def store_endpoint(payload)
      raw = payload.to_h.deep_symbolize_keys
      User.me.caches.set(ENDPOINT_KEY, {
        current:   raw,
        timestamp: now_ms,
      })
    end

    # For fields listed in INVALID_DEFAULTS, rewrite an `<invalid>` sentinel to
    # the default value BEFORE strip_invalid drops it. Otherwise strip_invalid
    # would remove the key from the payload, deep_merge would preserve the
    # previous non-zero value, and the projection would show phantom motion
    # after the car parked.
    def apply_invalid_defaults(data)
      return data unless data.is_a?(Hash)

      INVALID_DEFAULTS.each_with_object(data.dup) { |(key, default), h|
        h[key] = default if h[key] == INVALID_SENTINEL
      }
    end

    # Drop `<invalid>` leaves AND collapse hashes/arrays that become empty
    # after stripping — empty containers still deep-merge as "present" and
    # would overwrite known-good prior values.
    def strip_invalid(value)
      case value
      when Hash
        cleaned = value.each_with_object({}) { |(k, v), h|
          stripped = strip_invalid(v)
          h[k] = stripped unless stripped.nil?
        }
        cleaned.empty? ? nil : cleaned
      when Array
        arr = value.map { |v| strip_invalid(v) }.compact
        arr.empty? ? nil : arr
      when INVALID_SENTINEL
        nil
      else
        value
      end
    end

    def sections_in_record(cleaned)
      keys = cleaned.keys.to_set(&:to_sym)
      TELEMETRY_SECTIONS.select { |_, fields| fields.any? { |f| keys.include?(f) } }.keys
    end

    # Compose the projected car_data from both raw caches.
    def compose(endpoint_cache_hash, telemetry_cache_hash)
      ep = endpoint_cache_hash[:current] || {}
      tel = telemetry_cache_hash[:current] || {}
      sec_ts = (telemetry_cache_hash[:section_ts] || {}).symbolize_keys
      field_ts = (telemetry_cache_hash[:field_ts] || {}).symbolize_keys
      ep_ts = endpoint_cache_hash[:timestamp]

      {
        state:      ep[:state] || (tel.any? ? "online" : nil),
        name:       tel[:VehicleName] || ep[:vehicle_state]&.dig(:vehicle_name),
        vin:        tel[:Vin] || ep[:vin],

        location:   compose_location(ep, tel, sec_ts),
        battery:    compose_battery(ep, sec_ts),
        charging:   compose_charging(ep, tel, sec_ts, ep_ts),
        drive:      compose_drive(ep, tel, sec_ts, field_ts, ep_ts),
        trip:       compose_trip(ep, tel, sec_ts, field_ts, ep_ts),
        climate:    compose_climate(ep, tel, sec_ts),
        doors:      compose_doors(ep, tel, sec_ts),
        windows:    compose_windows(ep, tel, sec_ts),
        tires:      compose_tires(ep, tel, sec_ts),
        odometer:   compose_odometer(ep, tel, sec_ts),

        updated_at: max_ts(*endpoint_data_ts(ep), *sec_ts.values),
      }.compact
    end

    def compose_location(ep, tel, sec_ts)
      loc = tel[:Location]
      lat = (loc.is_a?(Hash) ? (loc[:latitude] || loc[:lat]) : nil) || ep.dig(:drive_state, :latitude)
      lng = (loc.is_a?(Hash) ? (loc[:longitude] || loc[:lng] || loc[:lon]) : nil) || ep.dig(:drive_state, :longitude)
      return nil unless lat && lng

      {
        lat:     lat.to_f.round(6),
        lng:     lng.to_f.round(6),
        name:    location_name(lat, lng),
        heading: (tel[:GpsHeading] || ep.dig(:drive_state, :heading))&.to_f&.round(1),
        ts:      sec_ts[:location] || ep.dig(:drive_state, :timestamp),
      }.compact
    end

    def compose_battery(ep, _sec_ts)
      cs = ep[:charge_state]
      return nil unless cs.is_a?(Hash)
      return nil unless cs[:battery_level].present? || cs[:battery_range].present?

      {
        pct:      cs[:battery_level],
        range_mi: cs[:battery_range]&.to_f&.round(1),
        ts:       cs[:timestamp],
      }.compact
    end

    def compose_charging(ep, tel, sec_ts, ep_ts)
      # Neither source is perfect for charging state:
      #   - Telemetry pushes live transitions but never pushes "Disconnected"
      #     on unplug (Tesla just goes quiet, leaving a stale "Idle").
      #   - The endpoint poll cleanly reports "Disconnected" — but endpoint
      #     polls are on-demand, so its cached snapshot can be arbitrarily
      #     stale in the OTHER direction after a plug-in.
      # Resolution: use whichever source has the more recent timestamp.
      # Ties or missing timestamps favor telemetry (usually the live source).
      tel_state = tel[:ChargeState]
      tel_state = nil if TRANSIENT_CHARGE_STATES.include?(tel_state)
      ep_state  = ep.dig(:charge_state, :charging_state)

      state = if tel_fresher?(sec_ts[:charging], ep_ts)
        tel_state || ep_state
      else
        ep_state || tel_state
      end
      return nil unless state

      cs = ep[:charge_state] || {}
      {
        state:    state,
        active:   ["Disconnected", "Complete", "Idle", "NoPower"].exclude?(state),
        rate_mph: cs[:charge_rate]&.to_f,
        amps:     cs[:charger_actual_current],
        voltage:  cs[:charger_voltage],
        eta_min:  cs[:minutes_to_full_charge],
        ts:       sec_ts[:charging] || cs[:timestamp],
      }.compact
    end

    def compose_drive(ep, tel, sec_ts, field_ts, ep_ts)
      speed_raw = tel[:VehicleSpeed]
      speed = speed_raw.is_a?(Numeric) ? speed_raw : ep.dig(:drive_state, :speed)
      # Gear is pushed on CHANGE, not on an interval — so a single missed
      # record (bridge restart, downtime, a drop) leaves the merged value
      # wrong until the next physical shift, which can be hours. That's how
      # "69mph, in Park" happened: the P→D record was lost and nothing
      # resent it. So Gear can't be trusted just because it exists; prefer
      # whichever source is actually fresher, the same way charging does.
      #
      # It has to be the per-FIELD stamp, not sec_ts[:drive] — VehicleSpeed
      # is in the same section and pushes constantly while driving, which
      # would make a stale Gear look freshly-confirmed on every speed tick.
      # The normalizer absorbs whatever enum shape Tesla sends ("ShiftStateP"
      # vs bare "P" vs unknown).
      tel_shift = normalize_shift(tel[:Gear])
      ep_shift  = ep.dig(:drive_state, :shift_state)
      shift = if tel_fresher?(field_ts[:Gear], ep_ts)
        tel_shift || ep_shift
      else
        ep_shift || tel_shift
      end

      {
        speed_mph: speed.to_i,
        moving:    speed.to_i.positive?,
        shift:     shift,
        parked:    shift.to_s == "P",
        ts:        sec_ts[:drive] || ep.dig(:drive_state, :timestamp),
      }.compact
    end

    # Tesla fleet-telemetry pushes ShiftState as an enum. The expected
    # shape (by analogy with HvacPower → "HvacPowerStateOn") is the
    # enum-name string "ShiftStateP" / "ShiftStateR" / etc. We also
    # tolerate the short form ("P") that the endpoint poll uses, and
    # the integer form (2..5) just in case Tesla serializes that way.
    # `<invalid>` is already stripped upstream by strip_invalid, so we
    # only see real values here. Unknown shapes → nil (compose drops it
    # via .compact) so a misformatted value never poisons the bool.
    def normalize_shift(raw)
      return nil if raw.blank?

      s = raw.to_s
      return ::Regexp.last_match(1) if s =~ /\AShiftState([PRND])\z/
      return s if s.match?(/\A[PRND]\z/)
      { "2" => "P", "3" => "R", "4" => "N", "5" => "D" }[s]
    end

    # A route is only as true as the last thing said about it, so this asks
    # freshness rather than presence — the same way compose_charging and
    # compose_drive resolve their two sources.
    #
    # Presence alone made a parked car 23 miles from its own driveway. On
    # 2026-09-17 the car reached home at 12:04 and shifted into P at 12:09, and
    # the dashboard still read "→ Home (23mi/26min)" at 12:31: the figures came
    # from the 11:39 poll, when the car really was 23 miles out, and nothing
    # overwrote them until the next poll at 12:25. Polls are hourly once the car
    # is parked and not charging, so the window is as wide as the gap between
    # arriving and whenever someone next opens the dashboard — all of it under a
    # timeago reading "just now", because `updated_at` is the max over every
    # section and telemetry keeps streaming the other ten.
    def compose_trip(ep, tel, sec_ts, field_ts, ep_ts)
      miles_ep   = ep.dig(:drive_state, :active_route_miles_to_arrival)
      minutes_ep = ep.dig(:drive_state, :active_route_minutes_to_arrival)
      routing_ep = !(miles_ep.nil? && minutes_ep.nil?)
      # Tesla's own stamp for the data, never the request clock: a poll that
      # reached an asleep car returns the same snapshot at a fresh wall time.
      poll_ts    = ep.dig(:drive_state, :timestamp) || ep_ts
      # Any trip field arriving stamps the section, so this is when telemetry
      # last mentioned the route — and it only mentions one while it has one.
      told_ts    = sec_ts[:trip]

      # Whoever spoke last wins: telemetry saying anything at all means a route
      # was loaded, and a poll is taken at its word either way.
      return nil unless tel_fresher?(told_ts, poll_ts) || routing_ep

      confirmed_ts = max_ts(told_ts, (poll_ts if routing_ep))
      return nil unless trip_still_current?(confirmed_ts)

      miles, minutes = trip_countdown(ep, tel, field_ts, poll_ts)
      {
        destination:        trip_destination(ep, tel),
        miles_to_arrival:   miles&.to_f&.round(2),
        minutes_to_arrival: minutes&.to_f&.round(2),
        ts:                 confirmed_ts,
      }.compact
    end

    # Both sources carry the countdown; prefer whichever restated it last. The
    # endpoint's is only as new as the last poll, and telemetry's is only as new
    # as the last push, so neither is reliably the fresher one.
    def trip_countdown(ep, tel, field_ts, poll_ts)
      miles_ep     = ep.dig(:drive_state, :active_route_miles_to_arrival)
      minutes_ep   = ep.dig(:drive_state, :active_route_minutes_to_arrival)
      countdown_ts = max_ts(*field_ts.values_at(:MilesToArrival, :MinutesToArrival))

      if tel_fresher?(countdown_ts, poll_ts)
        [tel[:MilesToArrival] || miles_ep, tel[:MinutesToArrival] || minutes_ep]
      else
        [miles_ep || tel[:MilesToArrival], minutes_ep || tel[:MinutesToArrival]]
      end
    end

    # The endpoint's destination carries the address string Tesla resolved for
    # it, so it leads; telemetry's bare coords answer for a route the last poll
    # predates entirely.
    def trip_destination(ep, tel)
      from_ep = normalize_loc(ep_route_dest(ep), ep.dig(:drive_state, :active_route_destination))
      from_ep || normalize_loc(tel[:DestinationLocation])
    end

    def trip_still_current?(ts)
      return false if ts.nil?

      (now_ms - ts) <= TRIP_EVIDENCE_WINDOW_MS
    end

    def compose_climate(ep, tel, sec_ts)
      hvac = tel[:HvacPower]
      hvac_on = hvac == "HvacPowerStateOn" if hvac.is_a?(String)
      hvac_on = ep.dig(:climate_state, :is_climate_on) if hvac_on.nil?

      inside_c  = tel[:InsideTemp]  || ep.dig(:climate_state, :inside_temp)
      outside_c = tel[:OutsideTemp] || ep.dig(:climate_state, :outside_temp)
      set_c     = ep.dig(:climate_state, :driver_temp_setting)

      {
        hvac_on:   hvac_on,
        inside_f:  c_to_f(inside_c),
        outside_f: c_to_f(outside_c),
        set_f:     c_to_f(set_c),
        ts:        sec_ts[:climate] || ep.dig(:climate_state, :timestamp),
      }.compact
    end

    def compose_doors(ep, tel, sec_ts)
      ds = tel[:DoorState] if tel[:DoorState].is_a?(Hash)
      v  = ep[:vehicle_state] || {}
      out = DOOR_KEYS.each_with_object({}) { |(key, tel_key), h|
        h[key] = ds ? ds[tel_key] : v[DOOR_ENDPOINT_FALLBACK[key]]
      }
      out[:locked] = tel[:Locked].nil? ? v[:locked] : tel[:Locked]
      out[:ts] = sec_ts[:doors] || v[:timestamp]
      out.compact
    end

    def compose_windows(ep, tel, sec_ts)
      out = ::TeslaCacheStore::WINDOW_KEYS.each_with_object({}) { |(key, tel_key), h|
        raw = tel[tel_key]
        raw = ep.dig(:vehicle_state, :"#{key}_window") if raw.nil?
        # Telemetry sends strings ("WindowStateClosed"/"WindowStateVent");
        # endpoint poll sends ints (0/1). Both → bool: closed=false, open=true.
        h[key] = if raw.is_a?(String)
          raw != "WindowStateClosed"
        elsif raw.nil?
          nil
        else
          raw.to_i.positive?
        end
      }
      out[:ts] = sec_ts[:windows] || ep.dig(:vehicle_state, :timestamp)
      out.compact
    end

    def compose_tires(ep, tel, sec_ts)
      v = ep[:vehicle_state] || {}
      out = ::TeslaCacheStore::TIRE_TEL_KEYS.each_with_object({}) { |(t, tel_key), h|
        raw = tel[tel_key] || v[:"tpms_pressure_#{t}"]
        h[:"#{t}_psi"]  = bar_or_psi_to_psi(raw)
        h[:"#{t}_soft"] = v[:"tpms_soft_warning_#{t}"] == true
        h[:"#{t}_hard"] = v[:"tpms_hard_warning_#{t}"] == true
      }
      out[:ts] = sec_ts[:tires] || v[:timestamp]
      out.compact
    end

    def compose_odometer(ep, tel, sec_ts)
      raw = tel[:Odometer] || ep.dig(:vehicle_state, :odometer)
      return nil if raw.nil?

      { mi: raw.to_f.round(1), ts: sec_ts[:odometer] || ep.dig(:vehicle_state, :timestamp) }.compact
    end

    def ep_route_dest(ep)
      lat = ep.dig(:drive_state, :active_route_latitude)
      lng = ep.dig(:drive_state, :active_route_longitude)
      return nil if lat.nil? && lng.nil?

      { latitude: lat, longitude: lng }
    end

    def normalize_loc(loc, address=nil)
      return nil unless loc.is_a?(Hash)

      lat = loc[:latitude] || loc[:lat]
      lng = loc[:longitude] || loc[:lng] || loc[:lon]
      return nil if lat.nil? && lng.nil?

      {
        lat:     lat&.to_f&.round(6),
        lng:     lng&.to_f&.round(6),
        name:    (location_name(lat, lng) if lat && lng),
        address: address,
      }.compact
    end

    def location_name(lat, lng)
      book = User.me.address_book
      contact = book.find_contact_near([lat, lng])
      return contact.name if contact.respond_to?(:name) && contact.name.present?

      book.reverse_geocode([lat, lng], get: :city).presence
    end

    def max_ts(*values) = values.compact.max

    def now_ms = (Time.current.to_f * 1000).round

    # `updated_at` answers "when did Tesla last tell us something", so only data
    # that actually arrived may move it. A poll that reaches Tesla and comes back
    # with the same asleep-car snapshot is not an update, and stamping it with
    # the request clock made a stream that had been dead for 18 hours read as
    # minutes old. Telemetry's `section_ts` already means "a record arrived";
    # these are the endpoint's equivalent.
    def endpoint_data_ts(ep)
      ENDPOINT_TS_PATHS.map { |path| ep.dig(*path) }
    end

    # True when the telemetry section is at least as fresh as the endpoint
    # snapshot. Nil telemetry ts (no push received for this section) → endpoint
    # wins; nil endpoint ts (never polled) → telemetry wins.
    def tel_fresher?(tel_ts, ep_ts)
      return false if tel_ts.nil?
      return true if ep_ts.nil?

      tel_ts >= ep_ts
    end

    def c_to_f(c)
      return nil if c.nil?

      ((c.to_f * 9 / 5) + 32).round(1)
    end

    # Telemetry sends BAR (~3.0 for a healthy tire); endpoint sometimes sends
    # PSI directly. Anything above 10 we treat as already-PSI; otherwise
    # convert. <=0 = sensor offline → nil so downstream readers don't think
    # the tire is flat.
    def bar_or_psi_to_psi(raw)
      f = raw.to_f
      return nil unless f.positive?
      return f.round(1) if f > 10

      (f * BAR_TO_PSI).round(1)
    end
  end
end
