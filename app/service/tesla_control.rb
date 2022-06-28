# https://tesla-api.timdorr.com/

class TeslaControl
  BASE_HEADERS = {
    "User-Agent": "PortfolioBot/1.0",
    "Content-Type": "application/json",
  }
  STABLE_STATE = DataStorage[:tesla_stable_state] ||= SecureRandom.hex
  CODE_VERIFIER = DataStorage[:tesla_code_verifier] ||= rand(36**86).to_s(36)
  CODE_CHALLENGE = Base64.urlsafe_encode64(Digest::SHA256.hexdigest(CODE_VERIFIER))

  def self.authorize
    # Open in browser
    params = {
      client_id: :ownerapi,
      code_challenge: CODE_CHALLENGE,
      code_challenge_method: :S256,
      redirect_uri: "https://auth.tesla.com/void/callback",
      response_type: :code,
      scope: "openid email offline_access",
      state: STABLE_STATE,
      login_hint: "rocco11nicholls@gmail.com",
    }
    "https://auth.tesla.com/oauth2/v3/authorize?#{params.to_query}"
    # Login and copy the `code` param from the redirect
    # then call TeslaControl.subscribe(code)
  end

  def self.subscribe(code)
    new.subscribe(code)
  end

  def initialize(car=nil)
    @access_token = DataStorage[:tesla_access_token]
    @refresh_token = DataStorage[:tesla_refresh_token]

    @car = car || Tesla.new(self)
  end

  def subscribe(code)
    auth(
      grant_type:    :authorization_code,
      client_id:     :ownerapi,
      code:          code,
      code_verifier: CODE_VERIFIER,
      redirect_uri:  "https://auth.tesla.com/void/callback",
    )

    self
  end

  def refresh
    raise "Cannot refresh without refresh token" if @refresh_token.blank?

    auth(
      grant_type:    :refresh_token,
      client_id:     :ownerapi,
      refresh_token: @refresh_token,
      scope:         "openid email offline_access"
    )

    true
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
    loc = [data.dig(:drive_state, :latitude), data.dig(:drive_state, :longitude)]
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
    if locked
      command(:door_unlock)
    else
      command(:door_lock)
    end
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

  def set_temp(temp_F)
    # Tesla expects temp in Celsius
    temp_C = ((temp_F - 32) * (5/9.to_f)).round(1)
    command(:set_temps, driver_temp: temp_C)
  end

  def heat_driver
    command(:remote_seat_heater_request, heater: 0, level: 3)
  end

  def heat_passenger
    command(:remote_seat_heater_request, heater: 1, level: 3)
  end

  def vehicle_data
    get("vehicles/#{vehicle_id}/latest_vehicle_data")
  end

  def vehicle_id
    @vehicle_id ||= DataStorage[:tesla_car_id] ||= begin
      get(:vehicles)[0][:id] # Only have 1 car, so just get the first one
    end
  end

  def wake_up
    start = Time.current.to_i

    loop do
      raise "Timed out waiting to wake up" if Time.current.to_i - start > 35

      break true if wake_vehicle
      sleep (rand * 5)
    end
  end

  private

  def command(cmd, params={})
    post_vehicle("command/#{cmd}", params)
  end

  def parse_to(val, truthy, falsy)
    val = val.to_s.to_sym
    return :toggle if val == :toggle
    return truthy if val == :open
    return falsy if val == :close

    val
  end

  def post_vehicle(endpoint, params={})
    raise "Cannot post without access token" if @access_token.blank?

    res = RestClient.post(
      "https://owner-api.teslamotors.com/api/1/vehicles/#{vehicle_id}/#{endpoint}",
      params.to_json,
      BASE_HEADERS.merge(Authorization: "Bearer #{@access_token}")
    )

    JSON.parse(res.body, symbolize_names: true).dig(:response)
  rescue RestClient::ExceptionWithResponse => err
    return wake_up && retry if err.response.code == 408
    return refresh && retry if err.response.code == 401
    raise err
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to parse json from Tesla#post(#{endpoint}):\n#{params}\nCode: #{res.code}\n```#{res.body}```")
  end

  def wake_vehicle
    res = RestClient.post(
      "https://owner-api.teslamotors.com/api/1/vehicles/#{vehicle_id}/wake_up",
      {},
      BASE_HEADERS.merge(Authorization: "Bearer #{@access_token}")
    )

    state = JSON.parse(res.body, symbolize_names: true).dig(:response, :state)
    state == "online"
  rescue RestClient::ExceptionWithResponse => err
    return wake_up && retry if err.response.code == 408
    return refresh && retry if err.response.code == 401
    raise err
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to parse json from Tesla#wake_vehicle:\nCode: #{res.code}\n```#{res.body}```")
  end

  def get(endpoint)
    raise "Cannot get without access token" if @access_token.blank?

    res = RestClient.get(
      "https://owner-api.teslamotors.com/api/1/#{endpoint}",
      BASE_HEADERS.merge(Authorization: "Bearer #{@access_token}")
    )

    JSON.parse(res.body, symbolize_names: true).dig(:response)
  rescue RestClient::ExceptionWithResponse => err
    return wake_up && retry if err.response.code == 408
    return refresh && retry if err.response.code == 401
    raise err
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to parse json from Tesla#get(#{endpoint}):\nCode: #{res.code}\n```#{res.body}```")
  end

  def auth(params)
    res = RestClient.post(
      "https://auth.tesla.com/oauth2/v3/token",
      params.to_json,
      BASE_HEADERS
    )

    json = JSON.parse(res.body, symbolize_names: true)

    @refresh_token = DataStorage[:tesla_refresh_token] = json[:refresh_token]
    @access_token = DataStorage[:tesla_access_token] = json[:access_token]
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to auth Tesla:\nCode: #{res.code}\n```#{res.body}```")
  end
end
