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

  # Tire pressure threshold in PSI — below this triggers soft warning
  TIRE_PRESSURE_LOW = 39.0

  def self.process(data)
    new(data).process
  end

  def initialize(data)
    @data = data.to_h.symbolize_keys
    @user = User.me
    @car_data = @user.caches.get(:car_data) || {}
    @prev_speed = @car_data.dig(:drive_state, :speed).to_i
    @prev_charge_state = @car_data.dig(:charge_state, :charging_state)
  end

  def process
    map_fields
    handle_location
    handle_charge_state
    handle_door_state

    @car_data[:state] = :online
    @car_data[:timestamp] = (Time.current.to_f * 1000).round

    @user.caches.set(:car_data, @car_data)

    detect_drive_changes
    detect_charge_changes
    check_tire_pressure
    fire_general_trigger

    TeslaCommand.broadcast
  end

  private

  def map_fields
    FIELD_MAP.each do |telemetry_key, (section, field)|
      next unless @data.key?(telemetry_key)

      value = extract_value(@data[telemetry_key])
      @car_data[section] ||= {}
      @car_data[section][field] = value
    end
  end

  def handle_location
    if @data.key?(:Location)
      loc = @data[:Location]
      @car_data[:drive_state] ||= {}
      if loc.is_a?(Hash)
        @car_data[:drive_state][:latitude] = loc[:latitude] || loc[:lat]
        @car_data[:drive_state][:longitude] = loc[:longitude] || loc[:lng] || loc[:lon]
      end
    end
  end

  def handle_charge_state
    if @data.key?(:ChargeState)
      value = extract_value(@data[:ChargeState])
      @car_data[:charge_state] ||= {}
      @car_data[:charge_state][:charging_state] = value
    end

    if @data.key?(:BatteryLevel)
      @car_data[:charge_state] ||= {}
      @car_data[:charge_state][:battery_level] = extract_value(@data[:BatteryLevel])
    end

    if @data.key?(:EstBatteryRange)
      @car_data[:charge_state] ||= {}
      @car_data[:charge_state][:battery_range] = extract_value(@data[:EstBatteryRange])
    end
  end

  def handle_door_state
    return unless @data.key?(:DoorState)

    # DoorState is a bitmask or structured value — map to individual door fields
    value = @data[:DoorState]
    return unless value.is_a?(Hash)

    @car_data[:vehicle_state] ||= {}
    { df: :DriverFront, pf: :PassengerFront, dr: :DriverRear, pr: :PassengerRear,
      ft: :FrontTrunk, rt: :RearTrunk }.each do |cache_key, door_key|
      @car_data[:vehicle_state][cache_key] = value[door_key] if value.key?(door_key)
    end
  end

  def detect_drive_changes
    return unless @data.key?(:VehicleSpeed)

    new_speed = @car_data.dig(:drive_state, :speed).to_i

    if @prev_speed.zero? && new_speed.positive?
      ::Jil.trigger(@user, :tesla_drive_start, speed: new_speed)
    elsif @prev_speed.positive? && new_speed.zero?
      ::Jil.trigger(@user, :tesla_drive_stop, {})
    end
  end

  def detect_charge_changes
    return unless @data.key?(:ChargeState)

    new_charge_state = @car_data.dig(:charge_state, :charging_state)
    return if new_charge_state == @prev_charge_state

    ::Jil.trigger(@user, :tesla_charge, {
      state: new_charge_state,
      previous: @prev_charge_state,
    })
  end

  def check_tire_pressure
    pressures = {
      fl: @car_data.dig(:vehicle_state, :tpms_pressure_fl),
      fr: @car_data.dig(:vehicle_state, :tpms_pressure_fr),
      rl: @car_data.dig(:vehicle_state, :tpms_pressure_rl),
      rr: @car_data.dig(:vehicle_state, :tpms_pressure_rr),
    }

    return unless pressures.values.any?

    chores = @user.list_by_name(:Chores)
    pressures.each do |tire, psi|
      next unless psi

      tirename = tire.to_s.split("").then { |dir, side|
        [dir == "f" ? "Front" : "Back", side == "l" ? "Left" : "Right"]
      }.join(" ")

      if psi.to_f < TIRE_PRESSURE_LOW
        chores.add("#{tirename} tire pressure low")
      else
        chores.remove("#{tirename} tire pressure low")
      end
    end
  end

  def fire_general_trigger
    ::Jil.trigger(@user, :tesla, @data)
  end

  def extract_value(val)
    return val unless val.is_a?(Hash)

    # Fleet Telemetry wraps values in various typed containers
    val[:value] || val[:stringValue] || val[:intValue] || val[:floatValue] || val[:boolValue] || val
  end
end
