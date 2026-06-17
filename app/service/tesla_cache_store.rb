# Two raw source-of-truth caches + the formatted `:car_data` view.
#
#   :tesla_telemetry  → fleet-telemetry pushes
#   :tesla_endpoint   → vehicle_data HTTP polls
#   :car_data         → formatted/cleaned/meta-augmented view that the
#                       dashboard cell, Jarvis commands, tire check, and
#                       every other reader consume
#
# Each of the two source caches has the same shape:
#   {
#     current: <deep-merged raw across every push from that source>,
#     history: [{ timestamp:, data: <raw payload> }, …]   # newest first, capped
#   }
#
# `current` and `history` are intentionally untouched — whatever Tesla sent
# is what we keep. Trust the telemetry; partial pushes (e.g. only the
# Location latitude changed) are exactly that — partial, and a deep_merge
# preserves any previously-set siblings. All normalization (BAR→PSI,
# window-state strings → 0/1, ChargeState "ClearFaults" filter, sentinel
# `"<invalid>"` skipping, DoorState key remapping, location_name lookup,
# etc.) happens during the `compose` that builds `:car_data`.
class TeslaCacheStore
  HISTORY_LIMIT = 10
  TELEMETRY_KEY = :tesla_telemetry
  ENDPOINT_KEY  = :tesla_endpoint
  CAR_DATA_KEY  = :car_data

  INVALID_SENTINEL = "<invalid>".freeze
  TRANSIENT_CHARGE_STATES = ["ClearFaults"].freeze
  DOOR_STATE_KEY_MAP = {
    df: :DriverFront, pf: :PassengerFront,
    dr: :DriverRear,  pr: :PassengerRear,
    ft: :TrunkFront,  rt: :TrunkRear,
  }.freeze

  class << self
    def record_telemetry(payload)
      store(TELEMETRY_KEY, payload)
      refresh_car_data!
    end

    def record_endpoint(payload)
      store(ENDPOINT_KEY, payload)
      refresh_car_data!
    end

    def telemetry_cache = User.me.caches.get(TELEMETRY_KEY) || {}
    def endpoint_cache  = User.me.caches.get(ENDPOINT_KEY)  || {}
    def car_data        = User.me.caches.get(CAR_DATA_KEY)  || {}

    def refresh_car_data!
      composed = compose(endpoint_cache[:current] || {}, telemetry_cache[:current] || {})
      User.me.caches.set(CAR_DATA_KEY, composed)
      composed
    end

    # Build car_data from the endpoint snapshot (full nested baseline)
    # overlaid by the telemetry running merge, with every transformation
    # the readers care about applied here so nothing has to redo it later.
    def compose(endpoint_current, telemetry_current)
      out = endpoint_current.deep_dup

      apply_field_map(out, telemetry_current)
      apply_location(out, telemetry_current)
      apply_charge_state(out, telemetry_current)
      apply_door_state(out, telemetry_current)
      normalize_tire_pressures!(out)
      normalize_window_states!(out)
      annotate_location_name!(out)
      bubble_timestamp!(out)

      out
    end

    private

    # `history` is intentionally raw — exactly what Tesla sent.
    # `current` deep-merges incoming pushes BUT strips `"<invalid>"` leaves
    # first, so a transient sensor-offline reading doesn't replace the last
    # known good value. The empty-hash collapsing keeps a `DoorState`
    # consisting entirely of `<invalid>` leaves from clobbering current's
    # full door snapshot.
    def store(key, payload)
      raw_symbolized = payload.to_h.deep_symbolize_keys
      cleaned = strip_invalid(raw_symbolized) || {}
      existing = User.me.caches.get(key) || {}
      current  = (existing[:current] || {}).deep_merge(cleaned)
      entry    = { timestamp: (Time.current.to_f * 1000).round, data: payload }
      history  = [entry, *(existing[:history] || [])].first(HISTORY_LIMIT)

      User.me.caches.set(key, { current: current, history: history })
    end

    # Recursively drop INVALID_SENTINEL leaves. Empty hashes/arrays that
    # remain after stripping collapse to nil so they don't deep-merge as
    # empty-but-present keys (which would still overwrite existing values).
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

    # PascalCase telemetry → nested snake_case car_data fields, skipping
    # any invalid/empty values so they don't blow away the endpoint baseline.
    def apply_field_map(out, telemetry_current)
      ::TeslaTelemetry::FIELD_MAP.each do |tel_key, (section, field)|
        val = telemetry_current[tel_key]
        next if invalid?(val)

        out[section] ||= {}
        out[section][field] = normalize_scalar(tel_key, val)
      end
    end

    # Partial overlay — only update each coordinate that's actually present
    # in the telemetry merge. Trust whatever Tesla sent; a lat-only update
    # means lng didn't change, not that it was reset.
    def apply_location(out, telemetry_current)
      loc = telemetry_current[:Location]
      return unless loc.is_a?(Hash)

      lat = loc[:latitude]  || loc[:lat]
      lng = loc[:longitude] || loc[:lng] || loc[:lon]
      return if lat.nil? && lng.nil?

      out[:drive_state] ||= {}
      out[:drive_state][:latitude]  = lat if lat.present?
      out[:drive_state][:longitude] = lng if lng.present?
    end

    def apply_charge_state(out, telemetry_current)
      cs = telemetry_current[:ChargeState]
      return unless cs.is_a?(String) && cs.present?
      return if TRANSIENT_CHARGE_STATES.include?(cs)

      out[:charge_state] ||= {}
      out[:charge_state][:charging_state] = cs
    end

    # Tesla telemetry's DoorState uses TrunkFront / TrunkRear (not FrontTrunk
    # / RearTrunk). The legacy car_data keys are df/pf/dr/pr/ft/rt.
    def apply_door_state(out, telemetry_current)
      ds = telemetry_current[:DoorState]
      return unless ds.is_a?(Hash)

      out[:vehicle_state] ||= {}
      DOOR_STATE_KEY_MAP.each do |cache_key, door_key|
        out[:vehicle_state][cache_key] = ds[door_key] if ds.key?(door_key)
      end
    end

    # Tesla returns tire pressures in BAR (both vehicle_data poll and the
    # TpmsPressure* telemetry fields). Normalize to PSI in car_data so the
    # threshold and dashboard logic operate in the unit a US driver reads.
    def normalize_tire_pressures!(out)
      return unless out[:vehicle_state].is_a?(Hash)

      [:fl, :fr, :rl, :rr].each do |tire|
        key = :"tpms_pressure_#{tire}"
        raw = out[:vehicle_state][key]
        next if raw.nil?

        psi = ::TeslaTelemetry.pressure_psi(raw)
        if psi
          out[:vehicle_state][key] = psi
        else
          # Sensor offline ("<invalid>", 0, etc.) — drop the key so readers
          # don't treat a stale value as current truth.
          out[:vehicle_state].delete(key)
        end
      end
    end

    # Telemetry sends "WindowStateClosed" / "WindowStateVent" etc.; legacy
    # readers do `.to_i.positive?` for any-open detection. Map closed → 0,
    # anything else → 1.
    def normalize_window_states!(out)
      return unless out[:vehicle_state].is_a?(Hash)

      [:fd_window, :fp_window, :rd_window, :rp_window].each do |key|
        raw = out[:vehicle_state][key]
        next unless raw.is_a?(String)

        out[:vehicle_state][key] = (raw == "WindowStateClosed" ? 0 : 1)
      end
    end

    # Meta: resolved name for the car's current location. Tries the user's
    # contacts (Home, Sarah's, etc.) before falling back to reverse-geocoded
    # city. Cheap once cached.
    def annotate_location_name!(out)
      lat = out.dig(:drive_state, :latitude)
      lng = out.dig(:drive_state, :longitude)
      return unless lat && lng

      book = User.me.address_book
      contact = book.find_contact_near([lat, lng])
      if contact.respond_to?(:name) && contact.name.present?
        out[:location_name] = contact.name
        return
      end

      city = book.reverse_geocode([lat, lng], get: :city)
      out[:location_name] = city if city.present?
    end

    def bubble_timestamp!(out)
      ts_candidates = [
        out[:timestamp],
        out.dig(:vehicle_state, :timestamp),
        telemetry_cache.dig(:history, 0, :timestamp),
        endpoint_cache.dig(:history, 0, :timestamp),
      ].compact
      out[:timestamp] = ts_candidates.max if ts_candidates.any?
    end

    def invalid?(val)
      return true if val.nil?
      return true if val == INVALID_SENTINEL
      return true if val.is_a?(String) && val.empty?
      return true if val.is_a?(Hash) && val.empty?

      false
    end

    def normalize_scalar(telemetry_key, val)
      if telemetry_key.to_s.end_with?("Window") && val.is_a?(String)
        return val == "WindowStateClosed" ? 0 : 1
      end

      val
    end
  end
end
