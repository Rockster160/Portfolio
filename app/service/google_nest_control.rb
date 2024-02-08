class GoogleNestControl
  PROJECT_ID = ENV.fetch("PORTFOLIO_GCP_PROJECT_ID")
  CLIENT_ID = ENV.fetch("PORTFOLIO_GCP_CLIENT_ID")
  CLIENT_SECRET = ENV.fetch("PORTFOLIO_GCP_CLIENT_SECRET")
  REDIRECT_URI = "https://ardesian.com/nest_subscribe"
  BASE_URL = "https://smartdevicemanagement.googleapis.com/v1"

  attr_accessor :access_token, :refresh_token

  def self.code_url
    params = {
      redirect_uri:  REDIRECT_URI,
      access_type:   :offline,
      prompt:        :consent,
      client_id:     CLIENT_ID,
      response_type: :code,
      scope:         "https://www.googleapis.com/auth/sdm.service",
    }

    "https://nestservices.google.com/partnerconnections/#{PROJECT_ID}/auth?#{params.to_query}"
    # Login and copy the `code` param from the redirect
    # then call GoogleNestControl.subscribe(code)
    # RefreshNestMessageWorker.perform_async
  end

  def self.subscribe(code)
    new.subscribe(code)
    # Remove from TODO
    ::User.me.lists.ilike(name: "Todo").take.list_items.by_formatted_name("Refresh Nest")&.soft_destroy
  end

  def initialize
    @access_token = DataStorage[:google_nest_access_token]
    @refresh_token = DataStorage[:google_nest_refresh_token]
  end

  def subscribe(code)
    auth(
      client_id:     CLIENT_ID,
      client_secret: CLIENT_SECRET,
      code:          code,
      grant_type:    :authorization_code,
      redirect_uri:  REDIRECT_URI,
    )

    self
  end

  def devices
    @devices ||= begin
      raise "No access token" if @access_token.blank?

      json = request(:get, "enterprises/#{PROJECT_ID}/devices")

      devices = json[:devices]&.map do |device_data|
        GoogleNestDevice.new(self).set_all(serialize_device(device_data))
      end || []
      DataStorage[:nest_devices] = devices.each_with_object({}) { |device, obj|
        obj[device.name] = device.to_json
      }
      devices
    end
  end

  def reload(device)
    json = request(:get, device.key)

    device.set_all(serialize_device(json))
  end

  def set_mode(device, mode)
    mode = mode.to_s.upcase.to_sym
    raise "Must be one of: [cool, heat]" unless mode.in?([:COOL, :HEAT])

    success = command(
      device,
      command: "sdm.devices.commands.ThermostatMode.SetMode",
      params: { mode: mode }
    )[:code] == 200

    device.current_mode = mode.downcase.to_sym if success

    success
  end

  def set_temp(device, temp)
    mode = device.current_mode.to_s

    success = command(
      device,
      command: "sdm.devices.commands.ThermostatTemperatureSetpoint.Set#{mode.titleize}",
      params: { "#{mode.downcase}Celsius": f_to_c(temp) }
    )[:code] == 200

    device.set_temp(mode.downcase.to_sym, temp) if success
    success
  end

  private

  def auth(params)
    raise "Should not auth in tests!" if Rails.env.test?

    res = RestClient.post("https://www.googleapis.com/oauth2/v4/token", params)
    json = JSON.parse(res.body, symbolize_names: true)

    @refresh_token = DataStorage[:google_nest_refresh_token] = json[:refresh_token] if json[:refresh_token].present?
    @access_token = DataStorage[:google_nest_access_token] = "#{json[:token_type]} #{json[:access_token]}"
  rescue RestClient::ExceptionWithResponse => err
    raise err
  rescue JSON::ParserError => err
    SlackNotifier.notify("Failed to auth Google Nest:\nCode: #{res.code}\n```#{res.body}```")
  end

  def refresh
    raise "No Refresh Token" if @refresh_token.blank?

    auth(
      client_id:     CLIENT_ID,
      client_secret: CLIENT_SECRET,
      refresh_token: @refresh_token,
      grant_type:    :refresh_token,
    )
  end

  def request(method, url, params={})
    raise "Should not request in tests!" if Rails.env.test?
    raise "Cannot request without access token" if @access_token.blank?
    retries ||= 0

    res = (
      if method == :get
        ::RestClient.get(
          "#{BASE_URL}/#{url}",
          base_headers.merge(params: params)
        )
      elsif method == :post
        ::RestClient.post(
          "#{BASE_URL}/#{url}",
          params.to_json,
          base_headers
        )
      end
    )

    JSON.parse(res.body, symbolize_names: true).merge(code: res.code)
  rescue ::RestClient::ExceptionWithResponse => err
    retries += 1
    return refresh && retry if retries < 2 && err.response.code == 401

    ::SlackNotifier.notify("Failed to request from GoogleNestControl##{method}(#{url}):\nCode: #{res&.code}\n```#{params}```\n```#{res&.body}```")
    raise err
  rescue JSON::ParserError => err
    ::SlackNotifier.notify("Failed to parse json from GoogleNestControl##{method}(#{url}):\nCode: #{res&.code}\n```#{params}```\n```#{res&.body}```")
    raise "Failed to parse json from GoogleNestControl##{method}"
  end

  def base_headers
    {
      "Content-Type": "application/json",
      "Authorization": @access_token,
    }
  end

  def command(device, data)
    request(:post, "#{device.key}:executeCommand", data)
  end

  def serialize_device(device_data)
    {
      key:      device_data.dig(:name),
      name:     device_data.dig(:parentRelations, 0, :displayName),
      humidity: device_data.dig(:traits, :"sdm.devices.traits.Humidity", :ambientHumidityPercent).to_i,
      current_mode: device_data.dig(:traits, :"sdm.devices.traits.ThermostatMode", :mode)&.downcase&.to_sym,
      current_temp: c_to_f(device_data.dig(:traits, :"sdm.devices.traits.Temperature", :ambientTemperatureCelsius)),
      hvac:     device_data.dig(:traits, :"sdm.devices.traits.ThermostatHvac", :status) == "ON",
      heat_set: c_to_f(device_data.dig(:traits, :"sdm.devices.traits.ThermostatTemperatureSetpoint", :heatCelsius)),
      cool_set: c_to_f(device_data.dig(:traits, :"sdm.devices.traits.ThermostatTemperatureSetpoint", :coolCelsius)),
    }
  end

  def c_to_f(c)
    return if c.blank?

    ((c * (9/5.to_f)) + 32).round
  end

  def f_to_c(ftemp)
    return if ftemp.blank?

    ((ftemp - 32) * (5/9.to_f))
  end
end
