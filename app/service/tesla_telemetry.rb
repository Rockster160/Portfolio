class TeslaTelemetry
  # Maps Fleet Telemetry field names (PascalCase) to the existing car_data cache
  # structure used by TeslaControl, TeslaCommand, and the dashboard.
  #
  # Fleet Telemetry sends data via MQTT → bridge → POST here.
  # We merge into the same User.me.caches.get(:car_data) hash so all existing
  # code (dashboard, Jarvis commands, etc.) works unchanged.

  FIELD_MAP = {
    VehicleSpeed:   [:drive_state, :speed],
    Odometer:       [:vehicle_state, :odometer],
    GpsHeading:     [:drive_state, :heading],
    Locked:         [:vehicle_state, :locked],
    FdWindow:       [:vehicle_state, :fd_window],
    FpWindow:       [:vehicle_state, :fp_window],
    RdWindow:       [:vehicle_state, :rd_window],
    RpWindow:       [:vehicle_state, :rp_window],
    TpmsPressureFl: [:vehicle_state, :tpms_pressure_fl],
    TpmsPressureFr: [:vehicle_state, :tpms_pressure_fr],
    TpmsPressureRl: [:vehicle_state, :tpms_pressure_rl],
    TpmsPressureRr: [:vehicle_state, :tpms_pressure_rr],
    InsideTemp:     [:climate_state, :inside_temp],
    OutsideTemp:    [:climate_state, :outside_temp],
  }.freeze

  # Tire pressure threshold in PSI — below this triggers soft warning.
  # Tesla reports `tpms_pressure_*` in BAR (both via vehicle_data and the
  # fleet-telemetry `TpmsPressure*` fields) — `pressure_psi` below converts
  # so this threshold stays in the unit a US driver actually reads.
  TIRE_PRESSURE_LOW = 39.0
  BAR_TO_PSI = 14.504

  # Tesla returns tire pressure in BAR (~2.5–3.1 for a healthy tire).
  # If we see a value above 10, assume it's already PSI (defensive — would
  # only happen if a future ingest path stored PSI directly). Magnitudes
  # below 10 are BAR and need converting.
  def self.pressure_psi(raw)
    raw_f = raw.to_f
    return nil unless raw_f.positive?
    return raw_f if raw_f > 10

    (raw_f * BAR_TO_PSI).round(1)
  end

  def self.process(data)
    new(data).process
  end

  def initialize(data)
    raw = data.to_h.symbolize_keys
    # Fleet Telemetry wraps every record as { data: {...}, metadata: {...},
    # msg: "record_payload", ... }. Unwrap to the inner :data hash if that's
    # what we got; if a caller hands us a flat hash directly (older API or
    # tests), use as-is.
    @data = raw[:data].is_a?(Hash) ? raw[:data].symbolize_keys : raw
    @metadata = raw[:metadata].is_a?(Hash) ? raw[:metadata].symbolize_keys : {}
    @user = User.me
    prev_car_data = @user.caches.get(:car_data) || {}
    @prev_speed = prev_car_data.dig(:drive_state, :speed).to_i
    @prev_charge_state = prev_car_data.dig(:charge_state, :charging_state)
  end

  def process
    # TeslaCacheStore handles all the raw recording, merging, and mapping
    # into the legacy car_data shape. We read back the composed result to
    # run the side-effect checks that TeslaTelemetry owns.
    @car_data = ::TeslaCacheStore.record_telemetry(@data)

    detect_drive_changes
    detect_charge_changes
    check_tire_pressure
    fire_general_trigger

    TeslaCommand.broadcast
  end

  private

  def detect_drive_changes
    return unless @data.key?(:VehicleSpeed)
    # Tesla sends the literal string "<invalid>" when the speed sensor is
    # offline (stopped, key out, etc.). That's NOT "speed is 0" — coercing
    # it to 0 was misfiring :tesla_drive_stop every time the car parked.
    return if @data[:VehicleSpeed] == "<invalid>"

    new_speed = @car_data.dig(:drive_state, :speed).to_i

    if @prev_speed.zero? && new_speed.positive?
      # Hash MUST be explicit braces — `::Jil.trigger`'s third positional
      # arg is `data` with a default, so bare keyword-style args
      # (`speed:`) get bound to the method's actual `**kwargs` (auth:,
      # auth_id:) under Ruby 3's kwarg separation and raise
      # `unknown keyword: :speed`.
      ::Jil.trigger(@user, :tesla_drive_start, { speed: new_speed })
    elsif @prev_speed.positive? && new_speed.zero?
      ::Jil.trigger(@user, :tesla_drive_stop, {})
    end
  end

  def detect_charge_changes
    return unless @data.key?(:ChargeState)
    # "ClearFaults" is a transient pulse Tesla emits on state-machine
    # housekeeping, not a real charging state. TeslaCacheStore filters it
    # from car_data already; skip the detection too.
    return if @data[:ChargeState] == "ClearFaults"

    new_charge_state = @car_data.dig(:charge_state, :charging_state)
    return if new_charge_state == @prev_charge_state

    ::Jil.trigger(@user, :tesla_charge, {
      state:    new_charge_state,
      previous: @prev_charge_state,
    })
  end

  # A real TPMS reading is always > 0 (anything <= 0 means sensor offline /
  # not reporting). Treat 0 as "no reading" so we don't fire false alarms.
  # Pressures are normalized to PSI via `pressure_psi` because Tesla
  # delivers BAR (~3.0 for a healthy tire); comparing 3.0 < 39 would
  # otherwise mark every tire as low.
  def check_tire_pressure
    real = {
      fl: self.class.pressure_psi(@car_data.dig(:vehicle_state, :tpms_pressure_fl)),
      fr: self.class.pressure_psi(@car_data.dig(:vehicle_state, :tpms_pressure_fr)),
      rl: self.class.pressure_psi(@car_data.dig(:vehicle_state, :tpms_pressure_rl)),
      rr: self.class.pressure_psi(@car_data.dig(:vehicle_state, :tpms_pressure_rr)),
    }
    return if real.values.all?(&:nil?)

    chores = @user.list_by_name(:Chores)
    real.each do |tire, psi|
      next if psi.nil?

      tirename = tire.to_s.chars.then { |dir, side|
        [dir == "f" ? "Front" : "Back", side == "l" ? "Left" : "Right"]
      }.join(" ")

      if psi < TIRE_PRESSURE_LOW
        chores.add("#{tirename} tire pressure low")
      else
        chores.remove("#{tirename} tire pressure low")
      end
    end
  end

  def fire_general_trigger
    ::Jil.trigger(@user, :tesla, @data)
  end
end
