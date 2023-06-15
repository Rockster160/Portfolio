# https://tesla-api.timdorr.com/

class TeslaError < StandardError; end
class TeslaControl
  attr_accessor :access_token, :refresh_token, :car

  BASE_HEADERS = {
    "User-Agent": "PortfolioBot/1.0",
    "Content-Type": "application/json",
    "Accept": "*/*",
    "accept-encoding": "deflate",
  }
  STABLE_STATE = DataStorage[:tesla_stable_state] ||= SecureRandom.hex
  CODE_VERIFIER = DataStorage[:tesla_code_verifier] ||= rand(36**86).to_s(36)
  CODE_CHALLENGE = Base64.urlsafe_encode64(Digest::SHA256.digest(CODE_VERIFIER), padding: false)

  def self.authorize
    # If this is still broken, try cleaning the challenge:
    # https://github.com/timdorr/tesla-api/discussions/689#discussioncomment-5013335
    # https://github.com/timdorr/tesla-api/discussions/689#discussioncomment-5074272
    # https://github.com/timdorr/tesla-api/discussions/689#discussioncomment-5062878

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
    # HTTParty.get(TeslaControl.authorize, headers: { "User-Agent": "PortfolioBot/1.0" })
    # Login and copy the `code` param from the redirect
    # then call TeslaControl.subscribe(code)
    # If this works, should allow just pasting the entire url into the Tesla cell and parse/update
    # https://github.com/timdorr/tesla-api/issues/431
    # Update this comment if new auth works
  end

  def self.subscribe(code)
    new.subscribe(code)
  end

  def self.quick(double_str)
    # https://tesla-info.com/tesla-token.php
    refresh, access = double_str.split(" ", 2)
    DataStorage[:tesla_access_token] = access
    DataStorage[:tesla_refresh_token] = refresh
    DataStorage[:tesla_forbidden] = false

    TeslaCommand.quick_command(:reload)
  end

  def self.local
    if new.refresh
      RestClient.post(
        "https://ardesian.com/webhooks/tesla_local",
        {
          access_token: DataStorage[:tesla_access_token],
          refresh_token: DataStorage[:tesla_refresh_token],
        }.to_json,
        BASE_HEADERS.merge(
          Authorization: ::ActionController::HttpAuthentication::Basic.encode_credentials(
            :Rockster160, ENV["LOCAL_ME_PASS"]
          )
        )
      )
    end
  end

  def initialize(car=nil)
    @access_token = DataStorage[:tesla_access_token]
    @refresh_token = DataStorage[:tesla_refresh_token]

    @car = car || Tesla.new(self)
  end

  def subscribe(code)
    DataStorage[:tesla_forbidden] = false
    success = auth(
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

    success = auth(
      grant_type:    :refresh_token,
      client_id:     :ownerapi,
      refresh_token: @refresh_token,
      scope:         "openid email offline_access"
    )

    success
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

  def navigate(address)
    address_params = {
      type: :share_ext_content_raw,
      locale: :"en-US",
      timestamp_ms: (Time.current.to_f * 1000).round,
      value: {
        "android.intent.extra.TEXT": address,
      },
    }

    command(:share, address_params)
  end

  def set_temp(temp_F)
    temp_F = [59, 82, temp_F.to_f].sort[1]
    # Tesla expects temp in Celsius
    temp_C = ((temp_F - 32) * (5/9.to_f)).round(1)
    command(:set_temps, driver_temp: temp_C)
    # For some reason sometimes when setting temp while car is sleeping, it instead sets to TEMP_MIN
    # To counter that, wait 5 seconds after command is performed and attempt to set the temp again
    TeslaVerifyTempWorker.perform_in(5.seconds, temp_F) if Rails.env.production?
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
    User.me.jarvis_cache.get(:car_data)
  end

  def vehicle_data
    @vehicle_data ||= get("vehicles/#{vehicle_id}/vehicle_data").tap { |car_data|
      User.me.jarvis_cache.set(:car_data, car_data)
    }
  end

  def loc
    [vehicle_data.dig(:drive_state, :latitude), vehicle_data.dig(:drive_state, :longitude)]
  end

  def vehicle_id
    @vehicle_id ||= DataStorage[:tesla_car_id] ||= begin
      vehicles = get(:vehicles)
      vehicle = vehicles.find { |car| car[:vin] == DataStorage[:tesla_car_vin] }
      vehicle ||= vehicles.first

      vehicle[:id]
    end
  end

  def wake_up
    start = Time.current.to_i

    loop do
      raise TeslaError, "Timed out waiting to wake up" if Time.current.to_i - start > 35

      break true if wake_vehicle
      sleep(rand * 5)
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
    raise TeslaError, "Currently Forbidden!" if DataStorage[:tesla_forbidden]
    raise "Should not POST in tests!" if Rails.env.test?
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
  rescue RestClient::Forbidden => err
    DataStorage[:tesla_forbidden] = true
    ActionCable.server.broadcast(:tesla_channel, { status: :forbidden })
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to parse json from Tesla#post(#{endpoint}):\n#{params}\nCode: #{res.code}\n```#{res.body}```")
  end

  def wake_vehicle
    raise TeslaError, "Currently Forbidden!" if DataStorage[:tesla_forbidden]

    res = RestClient.post(
      "https://owner-api.teslamotors.com/api/1/vehicles/#{vehicle_id}/wake_up",
      nil,
      BASE_HEADERS.merge(Authorization: "Bearer #{@access_token}")
    )

    state = JSON.parse(res.body, symbolize_names: true).dig(:response, :state)
    state == "online"
  rescue RestClient::GatewayTimeout => err
    return wake_up && retry
  rescue RestClient::Forbidden => err
    DataStorage[:tesla_forbidden] = true
    ActionCable.server.broadcast(:tesla_channel, { status: :forbidden })
  rescue RestClient::ExceptionWithResponse => err
    return wake_up && retry if err.response.code == 408
    return refresh && retry if err.response.code == 401
    raise err
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to parse json from Tesla#wake_vehicle:\nCode: #{res.code}\n```#{res.body}```")
  end

  def get(endpoint)
    raise TeslaError, "Currently Forbidden!" if DataStorage[:tesla_forbidden]
    raise "Should not GET in tests!" if Rails.env.test?
    raise "Cannot get without access token" if @access_token.blank?

    res = RestClient.get(
      "https://owner-api.teslamotors.com/api/1/#{endpoint}",
      BASE_HEADERS.merge(Authorization: "Bearer #{@access_token}")
    )

    JSON.parse(res.body, symbolize_names: true).dig(:response)
  rescue RestClient::GatewayTimeout => err
    return wake_up && retry
  rescue RestClient::Forbidden => err
    DataStorage[:tesla_forbidden] = true
    ActionCable.server.broadcast(:tesla_channel, { status: :forbidden })
  rescue RestClient::ExceptionWithResponse => err
    return wake_up && retry if err.response.code == 408
    return refresh && retry if err.response.code == 401
    raise err
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to parse json from Tesla#get(#{endpoint}):\nCode: #{res.code}\n```#{res.body}```")
  end

  def auth(params)
    raise "Should not auth in tests!" if Rails.env.test?

    res = RestClient.post(
      "https://auth.tesla.com/oauth2/v3/token",
      params.to_json,
      BASE_HEADERS
    )

    json = JSON.parse(res.body, symbolize_names: true)

    DataStorage[:tesla_forbidden] = false

    @refresh_token = DataStorage[:tesla_refresh_token] = json[:refresh_token]
    @access_token = DataStorage[:tesla_access_token] = json[:access_token]
    true
  rescue RestClient::Forbidden => err
    DataStorage[:tesla_forbidden] = true
    ActionCable.server.broadcast(:tesla_channel, { status: :forbidden })
    false
  rescue RestClient::GatewayTimeout => err
    return wake_up && retry
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to auth Tesla:\nCode: #{res.code}\n```#{res.body}```")
    false
  end
end
