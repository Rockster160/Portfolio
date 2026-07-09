# Two raw source-of-truth caches + the formatted `:car_data` view that every
# reader (dashboard, Jarvis, Jil tasks, tire check) consumes.
#
#   :tesla_telemetry → fleet-telemetry pushes (raw, deep-merged + section_ts)
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

  # Telemetry fields where `<invalid>` means "sensor offline" (parked/key-out)
  # rather than "no update this record". Normalized to a concrete default so
  # the deep_merge overwrites the last valid value instead of retaining it
  # forever — otherwise a stale 20mph reading survives the drive ending.
  INVALID_DEFAULTS = { VehicleSpeed: 0 }.freeze

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
      now_ms   = (Time.current.to_f * 1000).round
      existing = User.me.caches.get(TELEMETRY_KEY) || {}
      current  = (existing[:current] || {}).deep_merge(cleaned)
      section_ts = (existing[:section_ts] || {}).symbolize_keys
      sections_in_record(cleaned).each { |s| section_ts[s] = now_ms }
      entry    = { timestamp: now_ms, data: data }
      history  = [entry, *(existing[:history] || [])].first(HISTORY_LIMIT)

      User.me.caches.set(TELEMETRY_KEY, {
        current:    current,
        section_ts: section_ts,
        history:    history,
      })
    end

    # The endpoint poll is a full snapshot; replace rather than merge.
    def store_endpoint(payload)
      raw = payload.to_h.deep_symbolize_keys
      User.me.caches.set(ENDPOINT_KEY, {
        current:   raw,
        timestamp: (Time.current.to_f * 1000).round,
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

      {
        state:      ep[:state] || (tel.any? ? "online" : nil),
        name:       tel[:VehicleName] || ep[:vehicle_state]&.dig(:vehicle_name),
        vin:        tel[:Vin] || ep[:vin],

        location:   compose_location(ep, tel, sec_ts),
        battery:    compose_battery(ep, sec_ts),
        charging:   compose_charging(ep, tel, sec_ts),
        drive:      compose_drive(ep, tel, sec_ts),
        trip:       compose_trip(ep, tel, sec_ts),
        climate:    compose_climate(ep, tel, sec_ts),
        doors:      compose_doors(ep, tel, sec_ts),
        windows:    compose_windows(ep, tel, sec_ts),
        tires:      compose_tires(ep, tel, sec_ts),
        odometer:   compose_odometer(ep, tel, sec_ts),

        updated_at: max_ts(endpoint_cache_hash[:timestamp], *sec_ts.values),
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

    def compose_charging(ep, tel, sec_ts)
      state = tel[:ChargeState]
      state = nil if TRANSIENT_CHARGE_STATES.include?(state)
      state ||= ep.dig(:charge_state, :charging_state)
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

    def compose_drive(ep, tel, sec_ts)
      # The endpoint poll's shift_state is authoritative for "parked" — it's
      # a fresh full snapshot every time, so a "P" from it cannot be a stale
      # merge artifact. Telemetry's Gear is a deep_merged field and can hold
      # a stale "D" indefinitely if the car powered down without sending an
      # updated Gear. When the endpoint says P, force parked defaults so the
      # UI doesn't show phantom driving.
      ep_shift  = ep.dig(:drive_state, :shift_state)
      parked_ep = ep_shift.to_s == "P"

      # Telemetry's Gear is the live source when the endpoint doesn't
      # already say parked. The normalizer absorbs whatever enum shape
      # Tesla sends ("ShiftStateP" vs bare "P" vs unknown).
      tel_shift = normalize_shift(tel[:Gear])
      shift     = parked_ep ? "P" : (tel_shift || ep_shift)

      speed_raw = tel[:VehicleSpeed]
      speed_num = speed_raw.is_a?(Numeric) ? speed_raw : ep.dig(:drive_state, :speed)
      speed_i   = parked_ep ? 0 : speed_num.to_i

      {
        speed_mph: speed_i,
        moving:    speed_i.positive?,
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

    def compose_trip(ep, tel, sec_ts)
      miles   = tel[:MilesToArrival] || ep.dig(:drive_state, :active_route_miles_to_arrival)
      minutes = tel[:MinutesToArrival] || ep.dig(:drive_state, :active_route_minutes_to_arrival)
      dest    = tel[:DestinationLocation] || ep_route_dest(ep)
      origin  = tel[:OriginLocation]
      return nil if miles.nil? && minutes.nil? && dest.nil? && origin.nil?

      {
        destination:        normalize_loc(dest, ep.dig(:drive_state, :active_route_destination)),
        origin:             normalize_loc(origin),
        miles_to_arrival:   miles&.to_f&.round(2),
        minutes_to_arrival: minutes&.to_f&.round(2),
        ts:                 sec_ts[:trip] || ep.dig(:drive_state, :timestamp),
      }.compact
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

      { lat: lat&.to_f&.round(6), lng: lng&.to_f&.round(6), address: address }.compact
    end

    def location_name(lat, lng)
      book = User.me.address_book
      contact = book.find_contact_near([lat, lng])
      return contact.name if contact.respond_to?(:name) && contact.name.present?

      book.reverse_geocode([lat, lng], get: :city).presence
    end

    def max_ts(*values) = values.compact.max

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
