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
    info("Refresh Error", "[#{e.class}]: #{e.message}")
    raise
  end

  def pop_boot(direction=:toggle)
    direction = parse_to(direction, :open, :close)
    return proxy_command(:actuate_trunk, which_trunk: :rear) if direction == :toggle

    state = vehicle_data.dig(:vehicle_state, :rt).to_i > 0 ? :open : :close
    return if state == direction

    proxy_command(:actuate_trunk, which_trunk: :rear)
  end

  def windows(direction=:toggle)
    direction = parse_to(direction, :vent, :close)
    return proxy_command(:window_control, proxy_command: :vent) if direction == :open

    data = vehicle_data
    windows = [:fd, :fp, :rd, :rp]
    is_open = windows.any? { |window| data.dig(:vehicle_state, "#{window}_window".to_sym).to_i > 0 }
    state = direction == :toggle && !is_open ? :vent : :close

    proxy_command(:window_control, proxy_command: state, lat: loc[0], lon: loc[1])
  end

  def doors(direction=:toggle)
    direction = parse_to(direction, :unlock, :lock)
    return proxy_command(:door_lock) if direction == :lock
    return proxy_command(:door_unlock) if direction == :unlock

    locked = vehicle_data.dig(:vehicle_state, :locked)
    locked ? proxy_command(:door_unlock) : proxy_command(:door_lock)
  end

  def pop_frunk
    proxy_command(:actuate_trunk, which_trunk: :front)
  end

  def start_car
    proxy_command(:auto_conditioning_start)
  end

  def off_car
    proxy_command(:auto_conditioning_stop)
  end

  def honk
    proxy_command(:honk_horn)
  end

  def navigate(loc)
    address_params = {
      lat: loc[0],
      lon: loc[1],
      # order is 1 based, not 0 based
      order: 1, # Assume a new navigation point should be the next one, not the last one in order
    }

    command(:navigation_gps_request, address_params)
  end

  def set_temp(temp_F)
    temp_F = temp_F.to_f.clamp(59..82)
    # Tesla expects temp in Celsius
    temp_C = ((temp_F - 32) * (5/9.to_f)).round(1)
    proxy_command(:set_temps, driver_temp: temp_C, passenger_temp: temp_C)
    # For some reason sometimes when setting temp while car is sleeping, it instead sets to TEMP_MIN
    # To counter that, wait 5 seconds after proxy_command is performed and attempt to set the temp again
    # TeslaVerifyTempWorker.perform_in(5.seconds, temp_F) if Rails.env.production?
  end

  def heat_driver
    proxy_command(:remote_seat_heater_request, heater: 0, level: 3)
  end

  def heat_passenger
    proxy_command(:remote_seat_heater_request, heater: 1, level: 3)
  end

  def defrost(direction=true)
    direction = parse_to(direction, true, false)
    proxy_command(:set_preconditioning_max, on: direction)
  end

  def cached_vehicle_data
    User.me.jarvis_caches.get(:car_data)
  end

  def vehicle_data(wake: false)
    @vehicle_data = cached_vehicle_data if Rails.env.development?
    @vehicle_data ||= begin
      get("vehicles/#{vin}/vehicle_data?endpoints=drive_state%3Bvehicle_state%3Blocation_data%3Bcharge_state%3Bclimate_state", wake: wake)&.tap { |json|
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
      info("Vehicle Data Error", "[#{e.class}]: #{e.message}")
      cached_vehicle_data
    end
  end

  def loc
    [vehicle_data.dig(:drive_state, :latitude), vehicle_data.dig(:drive_state, :longitude)]
  end

  def vin
    @vin ||= DataStorage[:tesla_car_vin]
  end

  def wake_up
    res = proxy_post_vehicle(:wake_up)
    res&.dig(:response, :state) == "online"
  end

  private

  def tesla_exc_code(exc)
    # Tesla Proxy Server is correctly receiving the errors codes, but returning 500 for them.
    return exc.response.code unless exc.response.code == 500

    json = JSON.parse(exc.response.body, symbolize_names: true)
    case json[:error]
    when "vehicle unavailable: vehicle is offline or asleep" then 408
    else 500.tap { info("Unknown Status", "#{json[:error]}") }
    end
  rescue JSON::ParserError
    500
  end

  def wakeup_retry(max_attempts: 5, &block)
    tries = 0
    begin
      tries += 1
      block.call if tries <= max_attempts
    rescue RestClient::ExceptionWithResponse => res_exc
      case tesla_exc_code(res_exc)
      when 401
        if tries > 1 # Should only need to refresh on the first attempt
          info("Failed to reauthorize")
          raise
        end
        info("Token expired. Refreshing...")
        TeslaCommand.broadcast(loading: true)
        refresh
        tries -= 1 # Refresh doesn't count as an attempt
        info("Token refreshed. Trying again!")
        retry
      when 408
        if tries >= max_attempts
          TeslaCommand.broadcast(loading: false, sleeping: true)
          return false # Did not wake up
        end
        info("Attempting to wake up... (#{tries}/#{max_attempts})")
        TeslaCommand.broadcast(loading: true, sleeping: true)
        !wake_up && sleep(10) # Only sleep if still sleeping
        info("Trying again after wakeup!")
        retry
      else
        info("RestClient Wakeup Error", "[#{res_exc.class}]: #{res_exc.message}")
        raise
      end
    rescue => e
      info("Wakeup Error", "[#{e.class}]: #{e.message}")
    end
  end

  def get(url, wake: false)
    wakeup_retry(max_attempts: wake ? 5 : 1) {
      @api.get(url)
    }
  end

  def proxy_command(cmd, params={})
    wakeup_retry {
      info("#{cmd}")
      proxy_post_vehicle("command/#{cmd}", params)
    }
  rescue => e
    info("Command Error", "[#{e.class}]: #{e.message}")
  end

  def command(cmd, params={})
    wakeup_retry {
      info("#{cmd}")
      post_vehicle("command/#{cmd}", params)
    }
  rescue => e
    info("Command Error", "[#{e.class}]: #{e.message}")
  end

  def parse_to(val, truthy, falsy)
    val = val.to_s.to_sym
    return :toggle if val == :toggle
    return truthy if val == :open
    return falsy if val == :close

    val
  end

  def proxy_post_vehicle(endpoint, params={})
    raise "Should not POST in tests!" if Rails.env.test?

    @api.proxy_post("vehicles/#{vin}/#{endpoint}", params).tap { |res|
      info("Response", "#{res}")
    }
  end

  def post_vehicle(endpoint, params={})
    raise "Should not POST in tests!" if Rails.env.test?

    @api.post("vehicles/#{vin}/#{endpoint}", params).tap { |res|
      info("Response", "#{res}")
    }
  end

  def info(title, detail=nil)
    if detail
      detail = PrettyLogger.pretty_message(detail)
      detail = detail.gsub(/:(\w+)=>/, '\1: ')
    end
    ::PrettyLogger.info("\b\e[94m[TESLA]\n#{title}#{detail}\e[0m")
  end
end
