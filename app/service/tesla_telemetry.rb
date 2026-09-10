## After changing app/service/tesla_service.rb, run `request_telemetry` to update.
# ::Oauth::TeslaApi.me.request_telemetry
# ::Oauth::TeslaApi.me.check_telemetry

class TeslaTelemetry
  # Receives fleet-telemetry records (via bin/tesla_telemetry_bridge.rb →
  # /webhooks/tesla_telemetry → here) and runs side-effect detections.
  #
  # All the raw recording, deep-merging, unit conversion, and shape
  # projection happens in TeslaCacheStore. TeslaTelemetry only owns the
  # "did something interesting just change?" → Jil trigger logic.

  # Tire pressure threshold in PSI. Tesla reports BAR; TeslaCacheStore
  # converts to PSI during compose, so by the time we read car_data the
  # value is already in the unit a US driver reads.
  TIRE_PRESSURE_LOW = 39.0

  def self.process(data)
    new(data).process
  end

  def initialize(data)
    @raw = data.to_h.symbolize_keys
    @user = User.me
    @prev = @user.caches.get(:car_data) || {}
  end

  def process
    @car_data = ::TeslaCacheStore.record_telemetry(@raw)

    detect_drive_changes
    detect_shift_changes
    detect_park_changes
    detect_charge_changes
    detect_hvac_changes
    detect_travel_changes
    detect_trip_changes
    check_tire_pressure
    fire_general_trigger

    TeslaCommand.broadcast
  end

  private

  # "Drive" here = vehicle moving. Fires at every red-light → green-light
  # transition, which is noisy as a "car is on" signal — use
  # :tesla_hvac_on/:tesla_hvac_off for that. Speed-zero is also reported as
  # "<invalid>" by Tesla when the sensor is offline (key out, etc.); skip
  # those pushes so a mid-drive sensor glitch doesn't fire a phantom stop.
  # (TeslaCacheStore separately normalizes the sentinel to 0 in the cache
  # projection so the dashboard doesn't show stale motion.)
  def detect_drive_changes
    return unless field_present_in_record?(:VehicleSpeed)
    return if speed_in_record == "<invalid>"

    new_speed = @car_data.dig(:drive, :speed_mph).to_i
    prev_speed = @prev.dig(:drive, :speed_mph).to_i

    if prev_speed.zero? && new_speed.positive?
      payload = { speed: new_speed }
      ::Jil.trigger(@user, :tesla_drive_start, payload)
    elsif prev_speed.positive? && new_speed.zero?
      empty = {}
      ::Jil.trigger(@user, :tesla_drive_stop, empty)
    end
  end

  # Fires `:tesla_shift` on ANY gear transition (P→D, D→N, R→D, etc.)
  # so Jil tasks can pattern-match specific shifts via the listener
  # (e.g. `tesla_shift:shift:N`). `:tesla_parked` remains a dedicated
  # sugar for the P transition — see `detect_park_changes`.
  def detect_shift_changes
    return unless field_present_in_record?(:Gear)
    return if gear_in_record == "<invalid>"

    new_shift  = @car_data.dig(:drive, :shift)
    prev_shift = @prev.dig(:drive, :shift)
    return if new_shift == prev_shift
    return if new_shift.blank?

    payload = { shift: new_shift, previous: prev_shift }
    ::Jil.trigger(@user, :tesla_shift, payload)
  end

  # Fires `:tesla_parked` when the user shifts INTO Park. This is the
  # arrival signal — distinct from `:tesla_drive_stop` (every red light)
  # and from `:tesla_hvac_off` (powered down, may lag the actual park
  # by a moment while the user collects belongings). Only fires on the
  # transition INTO P, not on every record where shift is already P.
  def detect_park_changes
    return unless field_present_in_record?(:Gear)
    return if gear_in_record == "<invalid>"

    new_shift  = @car_data.dig(:drive, :shift)
    prev_shift = @prev.dig(:drive, :shift)
    return if new_shift == prev_shift

    if new_shift.to_s == "P"
      payload = { shift: new_shift, previous: prev_shift }
      ::Jil.trigger(@user, :tesla_parked, payload)
    end
  end

  def gear_in_record
    field_in_record(:Gear)
  end

  def detect_charge_changes
    return unless field_present_in_record?(:ChargeState)

    new_state = @car_data.dig(:charging, :state)
    prev_state = @prev.dig(:charging, :state)
    return if new_state == prev_state
    return if new_state.nil?

    payload = { state: new_state, previous: prev_state }
    ::Jil.trigger(@user, :tesla_charge, payload)
  end

  # HvacPower is the real "car has actually started / actually stopped"
  # signal — Tesla powers the HVAC system on when the driver gets in (or
  # when remote-start fires) and off when the car truly powers down.
  # Distinct from drive speed (red light != stopped).
  def detect_hvac_changes
    return unless field_present_in_record?(:HvacPower)

    new_on  = @car_data.dig(:climate, :hvac_on)
    prev_on = @prev.dig(:climate, :hvac_on)
    return if new_on == prev_on
    return if new_on.nil?

    scope = new_on ? :tesla_hvac_on : :tesla_hvac_off
    empty = {}
    ::Jil.trigger(@user, scope, empty)
  end

  # The car's own account of leaving home and coming back, which is the only
  # thing in the house that knows the car went somewhere without Rocco. Scoped
  # to the home boundary on purpose: every other place the car passes through
  # is a city name changing mid-drive, and none of those are legs.
  #
  # Fires `trytravel` rather than recording anything itself, so every source
  # arrives through the one Jil funnel the person can edit. `source: :tesla` is
  # what keeps it quiet — TravelResolver only lets the phone announce. A second
  # report goes out under `:phone` when the phone was aboard; see
  # `carrying_him?`.
  def detect_travel_changes
    return unless field_present_in_record?(:Location)
    # A car that has never reported a position has not crossed anything, so
    # the first push after a deploy isn't read as an arrival.
    return unless positioned?(@prev) && positioned?(@car_data)

    was_home = car_at_home?(@prev)
    now_home = car_at_home?(@car_data)
    return if was_home == now_home

    action = now_home ? :arrived : :departed
    ::Jil.trigger(@user, :trytravel, travel_payload(action, :tesla))
    ::Jil.trigger(@user, :trytravel, travel_payload(action, :phone)) if carrying_him?
  end

  # Whether the phone went with the car, asked at the moment the car crosses
  # the boundary — which is what makes it answerable without a timer or any
  # pending state. The car's own crossing is the clock.
  #
  # Sound on geometry rather than luck: Bluetooth reaches about ten metres and
  # the home boundary about a hundred. Riding in it, the pairing holds through
  # the crossing. Left behind, it dropped at the end of the driveway,
  # necessarily before. On 2026-09-10 the last edge was 10:22:15 and the car
  # crossed around 10:23 unpaired — the car went, he didn't, and this says so.
  # The same geometry answers the way back: Chelsea driving home crosses the
  # boundary while his phone is still a hundred metres away in the house.
  #
  # This is what keeps `travel:depart:home` firing at all. A pairing in the
  # garage no longer announces on its own (TravelResolver refuses it), and the
  # geofence has never once sent a departure, so without this nothing would
  # ever report him leaving his own house. On the arrival side the geofence
  # does work, and this is the belt to its braces — the merge window collapses
  # the two into one leg and only the first announces.
  def carrying_him?
    ::LocationCache.driving?
  end

  # No `via`: a pairing the car has corroborated by actually driving off is
  # not the raw radio edge that gets refused at home. Different evidence.
  def travel_payload(action, source)
    {
      action:    action,
      source:    source,
      location:  @car_data.dig(:location, :name),
      lat:       @car_data.dig(:location, :lat),
      lng:       @car_data.dig(:location, :lng),
      action    => @car_data.dig(:location, :name),
      timestamp: ::Time.current,
    }
  end

  def positioned?(data)
    coord_of(data).compact.length == 2
  end

  def car_at_home?(data)
    ::LocationCache.at_home?(coord_of(data))
  end

  def coord_of(data)
    [data.dig(:location, :lat), data.dig(:location, :lng)]
  end

  # Fires when a nav trip is started, updated, or ended. "Started" =
  # destination appeared. "Ended" = destination went away. "Updated" =
  # destination changed (rerouted to a new place).
  def detect_trip_changes
    new_trip  = @car_data[:trip]
    prev_trip = @prev[:trip]

    new_dest  = new_trip&.dig(:destination)
    prev_dest = prev_trip&.dig(:destination)

    if prev_dest.nil? && new_dest.present?
      payload = trip_payload(new_trip)
      ::Jil.trigger(@user, :tesla_trip_started, payload)
    elsif prev_dest.present? && new_dest.nil?
      empty = {}
      ::Jil.trigger(@user, :tesla_trip_ended, empty)
    elsif prev_dest.present? && new_dest.present? && dest_changed?(prev_dest, new_dest)
      payload = trip_payload(new_trip)
      ::Jil.trigger(@user, :tesla_trip_updated, payload)
    end
  end

  def trip_payload(trip)
    {
      destination_address: trip&.dig(:destination, :address),
      destination_lat:     trip&.dig(:destination, :lat),
      destination_lng:     trip&.dig(:destination, :lng),
      miles_to_arrival:    trip&.dig(:miles_to_arrival),
      minutes_to_arrival:  trip&.dig(:minutes_to_arrival),
    }
  end

  def dest_changed?(a, b)
    return false if a[:lat] == b[:lat] && a[:lng] == b[:lng]

    # A small lat/lng wiggle (GPS jitter, route refinement) shouldn't count
    # as a re-route. ~0.001 degrees ≈ 100 meters.
    (a[:lat].to_f - b[:lat].to_f).abs > 0.001 ||
      (a[:lng].to_f - b[:lng].to_f).abs > 0.001
  end

  # Maintain the Chores entries for soft-warned tires whose PSI is also
  # actually below threshold (both conditions must agree — Tesla's soft-
  # warning flag can stick on a stale cached value while the real pressure
  # is fine). Operates entirely on the composed car_data.tires section.
  def check_tire_pressure
    tires = @car_data[:tires]
    return unless tires.is_a?(Hash)

    chores = @user.list_by_name(:Chores)
    [:fl, :fr, :rl, :rr].each do |tire|
      psi  = tires[:"#{tire}_psi"]
      next if psi.nil?

      soft  = tires[:"#{tire}_soft"] == true
      label = "#{tire_label(tire)} tire pressure low"
      if soft && psi < TIRE_PRESSURE_LOW
        chores.add(label)
      else
        chores.remove(label)
      end
    end
  end

  def tire_label(tire)
    dir, side = tire.to_s.chars
    "#{dir == "f" ? "Front" : "Back"} #{side == "l" ? "Left" : "Right"}"
  end

  def fire_general_trigger
    ::Jil.trigger(@user, :tesla, @raw)
  end

  def speed_in_record
    field_in_record(:VehicleSpeed)
  end

  # Field lookup that tolerates both Fleet-Telemetry envelope shapes:
  #   * flat:           { VehicleSpeed: 10 }
  #   * record_payload: { data: { VehicleSpeed: 10 }, msg: "...", … }
  #   * alert/error:    { data: [ ... ], msg: "alerts" }  ← Array, NOT Hash
  #
  # The Array shape used to crash every detect_* via
  # `@raw.dig(:data, :Field)` → TypeError "no implicit conversion of
  # Symbol into Integer" (Array#dig refused the symbol). Anything that
  # isn't a Hash data section now returns nil instead.
  def field_in_record(name)
    return @raw[name] if @raw.key?(name)
    return @raw[:data][name] if @raw[:data].is_a?(::Hash) && @raw[:data].key?(name)

    nil
  end

  def field_present_in_record?(name)
    @raw.key?(name) || (@raw[:data].is_a?(::Hash) && @raw[:data].key?(name))
  end
end
