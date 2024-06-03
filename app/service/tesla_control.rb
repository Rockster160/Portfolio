class TeslaError < StandardError; end
class TeslaControl
  attr_accessor :api

  def self.me
    new(User.me)
  end

  def initialize(user)
    @api = ::Oauth::TeslaApi.new(user)
  end

  def code=(new_code)
    @api.code = new_code
  end

  def authorize
    @api.auth_url
  end

  def refresh
    @api.proxy_refresh
  rescue => e
    Jarvis.say("Tesla Refresh Error: [#{e.class}]: #{e.message}")
    raise
  end

  def pop_boot(direction=:toggle)
    direction = parse_to(direction, :open, :close)
    return command(:actuate_trunk, which_trunk: :rear) if direction == :toggle

    state = vehicle_data.dig(:vehicle_state, :rt).to_i > 0 ? :open : :close
    return if state == direction

    command(:actuate_trunk, which_trunk: :rear)
  end

  def windows(direction=:toggle)
    direction = parse_to(direction, :vent, :close)
    return command(:window_control, command: :vent) if direction == :open

    data = vehicle_data
    windows = [:fd, :fp, :rd, :rp]
    is_open = windows.any? { |window| data.dig(:vehicle_state, "#{window}_window".to_sym).to_i > 0 }
    state = direction == :toggle && !is_open ? :vent : :close

    command(:window_control, command: state, lat: loc[0], lon: loc[1])
  end

  def doors(direction=:toggle)
    direction = parse_to(direction, :unlock, :lock)
    return command(:door_lock) if direction == :lock
    return command(:door_unlock) if direction == :unlock

    locked = vehicle_data.dig(:vehicle_state, :locked)
    locked ? command(:door_unlock) : command(:door_lock)
  end

  def pop_frunk
    command(:actuate_trunk, which_trunk: :front)
  end

  def start_car
    command(:auto_conditioning_start)
  end

  def off_car
    command(:auto_conditioning_stop)
  end

  def honk
    command(:honk_horn)
  end

  def navigate(address)
    address_params = {
      type: :share_ext_content_raw,
      locale: :"en-US",
      timestamp_ms: (Time.current.to_f * 1000).round,
      value: { "android.intent.extra.TEXT": address },
    }

    command(:navigation_request, address_params)
  end

  def set_temp(temp_F)
    temp_F = temp_F.to_f.clamp(59..82)
    # Tesla expects temp in Celsius
    temp_C = ((temp_F - 32) * (5/9.to_f)).round(1)
    command(:set_temps, driver_temp: temp_C, passenger_temp: temp_C)
    # For some reason sometimes when setting temp while car is sleeping, it instead sets to TEMP_MIN
    # To counter that, wait 5 seconds after command is performed and attempt to set the temp again
    # TeslaVerifyTempWorker.perform_in(5.seconds, temp_F) if Rails.env.production?
  end

  def heat_driver
    command(:remote_seat_heater_request, heater: 0, level: 3)
  end

  def heat_passenger
    command(:remote_seat_heater_request, heater: 1, level: 3)
  end

  def defrost(direction=true)
    direction = parse_to(direction, true, false)
    command(:set_preconditioning_max, on: direction)
  end

  def cached_vehicle_data
    User.me.jarvis_caches.get(:car_data)
  end

  def vehicle_data(wake: false)
    @vehicle_data = cached_vehicle_data if Rails.env.development?
    @vehicle_data ||= @api.get("vehicles/#{vin}/vehicle_data?endpoints=drive_state%3Bvehicle_state%3Blocation_data%3Bcharge_state%3Bclimate_state", wake: wake)&.tap { |json|
      car_data = json&.dig(:response)
      cached_data = cached_vehicle_data
      break cached_data unless car_data

      car_data[:timestamp] = car_data.dig(:vehicle_state, :timestamp) # Bubble up to higher key

      User.me.jarvis_caches.set(:car_data, car_data)
      break car_data if car_data[:state] == "sleeping"

      if car_data[:vehicle_state]&.key?(:tpms_soft_warning_fl)
        list = User.me.list_by_name(:Chores)
        [:fl, :fr, :rl, :rr].each do |tire|
          tirename = tire.to_s.split("").then { |dir, side|
            [dir == "f" ? "Front" : "Back", side == "l" ? "Left" : "Right"]
          }.join(" ")

          if car_data.dig(:vehicle_state, "tpms_soft_warning_#{tire}".to_sym)
            list.add("#{tirename} tire pressure low")
          else
            list.remove("#{tirename} tire pressure low")
          end

          if car_data.dig(:vehicle_state, "tpms_hard_warning_#{tire}".to_sym)
            User.me.list_by_name(:TODO).add("#{tirename} tire pressure low")
          else
            User.me.list_by_name(:TODO).remove("#{tirename} tire pressure low")
          end
        end
      end
    } || cached_vehicle_data
  rescue => e
    Jarvis.say("Tesla Vehicle Data Error: [#{e.class}]: #{e.message}")
  end

  def loc
    [vehicle_data.dig(:drive_state, :latitude), vehicle_data.dig(:drive_state, :longitude)]
  end

  def vin
    @vin ||= DataStorage[:tesla_car_vin]
  end

  def wake_up
    wake_vehicle
    start = Time.current.to_i

    loop do
      if Time.current.to_i - start > 60
        TeslaCommand.broadcast(cached_vehicle_data.merge(sleeping: true, loading: false))
        Jarvis.say("BluZoro is too asleep to wake up, sir.")
        raise TeslaError, "Timed out waiting to wake up"
      end

      break true if wake_vehicle
      TeslaCommand.broadcast(cached_vehicle_data.merge(sleeping: true, loading: true))
      sleep(rand * 10)
    end
  end

  private

  def wake_vehicle
    res = post_vehicle(:wake_up)
    res&.dig(:response, :state) == "online"
  end

  def command(cmd, params={})
    post_vehicle("command/#{cmd}", params)
  rescue => e
    Jarvis.say("Tesla Command Error: [#{e.class}]: #{e.message}")
    ::PrettyLogger.info("Tesla Command Error: [#{e.class}]: #{e.message}\n[#{cmd}]: #{params}")
    # 401 Unauthorized (RestClient::Unauthorized)
    # refresh
  end

  def parse_to(val, truthy, falsy)
    val = val.to_s.to_sym
    return :toggle if val == :toggle
    return truthy if val == :open
    return falsy if val == :close

    val
  end

  def post_vehicle(endpoint, params={})
    raise "Should not POST in tests!" if Rails.env.test?

    @api.proxy_post("vehicles/#{vin}/#{endpoint}", params).tap { |res|
      ::PrettyLogger.info("Tesla Response: #{res}")
    }
  end
end
