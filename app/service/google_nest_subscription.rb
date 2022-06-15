class GoogleNestSubscription
  PROJECT_ID = ENV.fetch("PORTFOLIO_GCP_PROJECT_ID")
  CLIENT_ID = ENV.fetch("PORTFOLIO_GCP_CLIENT_ID")
  CLIENT_SECRET = ENV.fetch("PORTFOLIO_GCP_CLIENT_SECRET")
  REDIRECT_URI = "https://ardesian.com"

  attr_accessor :access_token, :refresh_token

  def self.code_url
    # Open this url in browser, go through steps, allowing everything.
    # After the redirect, copy the code= param and pass it to the subscribe method
    "https://nestservices.google.com/partnerconnections/#{PROJECT_ID}/auth?redirect_uri=#{REDIRECT_URI}&access_type=offline&prompt=consent&client_id=#{CLIENT_ID}&response_type=code&scope=https://www.googleapis.com/auth/sdm.service"
  end

  def self.subscribe(code=nil)
    DataStorage[:google_nest_code] = code if code.present?

    new.subscribe
  end

  def self.devices
    new.devices
  end

  def initialize
    @access_token = DataStorage[:google_nest_access_token]
    @refresh_token = DataStorage[:google_nest_refresh_token]
  end

  def subscribe
    return refresh if @refresh_token.present?

    retrieve_tokens
    self
  end

  def refresh
    retrieve_refresh_token
  end

  def devices
    @devices ||= begin
      subscribe if @access_token.blank?

      url = "https://smartdevicemanagement.googleapis.com/v1/enterprises/#{PROJECT_ID}/devices"
      headers = {
        "Content-Type": "application/json",
        "Authorization": @access_token,
      }

      res = RestClient.get(url, headers)
      json = JSON.parse(res.body).with_indifferent_access

      json[:devices].map do |device_data|
        GoogleNestDevice.new(subscription: self).set_all(serialize_device(device_data))
      end
    end
  end

  def set_mode(device, mode)
    mode = mode.to_s
    raise "Must be one of: [cool, heat]" unless mode.in?(["cool", "heat"])

    success = request_or_refresh {
      url = "https://smartdevicemanagement.googleapis.com/v1/#{device.key}:executeCommand"
      headers = {
        "Content-Type": "application/json",
        "Authorization": @access_token,
      }

      data = {
        command: "sdm.devices.commands.ThermostatMode.SetMode",
        params: {
          mode: mode.upcase
        }
      }

      RestClient.post(url, data.to_json, headers).code == 200
    }
    device.current_mode = mode.downcase.to_sym if success
    success
  end

  def set_temp(device, mode, temp)
    mode = mode.to_s

    success = request_or_refresh {
      url = "https://smartdevicemanagement.googleapis.com/v1/#{device.key}:executeCommand"
      headers = {
        "Content-Type": "application/json",
        "Authorization": @access_token,
      }

      data = {
        command: "sdm.devices.commands.ThermostatTemperatureSetpoint.Set#{mode.titleize}",
        params: {
          "#{mode.downcase}Celsius": f_to_c(temp)
        }
      }

      RestClient.post(url, data.to_json, headers).code == 200
    }
    device.set_temp(mode.to_sym, temp) if success
    success
  end

  def reload(device)
    success = request_or_refresh {
      url = "https://smartdevicemanagement.googleapis.com/v1/#{device.key}"
      headers = {
        "Content-Type": "application/json",
        "Authorization": @access_token,
      }

      res = RestClient.get(url, headers)
      json = JSON.parse(res.body).with_indifferent_access
      device.set_all(serialize_device(json))
    }
    device
  end

  private

  def serialize_device(device_data)
    {
      key:      device_data.dig(:name),
      name:     device_data.dig(:parentRelations, 0, :displayName),
      humidity: device_data.dig(:traits, "sdm.devices.traits.Humidity", :ambientHumidityPercent).to_i,
      current_mode: device_data.dig(:traits, "sdm.devices.traits.ThermostatMode", :mode).downcase.to_sym,
      current_temp: c_to_f(device_data.dig(:traits, "sdm.devices.traits.Temperature", :ambientTemperatureCelsius)),
      hvac:     device_data.dig(:traits, "sdm.devices.traits.ThermostatHvac", :status) == "ON",
      heat_set: c_to_f(device_data.dig(:traits, "sdm.devices.traits.ThermostatTemperatureSetpoint", :heatCelsius)),
      cool_set: c_to_f(device_data.dig(:traits, "sdm.devices.traits.ThermostatTemperatureSetpoint", :coolCelsius)),
    }
  end

  def retrieve_refresh_token
    raise "No Refresh Token" if @refresh_token.blank?

    params = {
      client_id:     CLIENT_ID,
      client_secret: CLIENT_SECRET,
      refresh_token: @refresh_token,
      grant_type:    "refresh_token",
    }

    res = RestClient.post("https://www.googleapis.com/oauth2/v4/token", params)
    json = JSON.parse(res.body).with_indifferent_access

    @access_token = DataStorage[:google_nest_access_token] = "#{json[:token_type]} #{json[:access_token]}"
  end

  def retrieve_tokens
    params = {
      client_id:     CLIENT_ID,
      client_secret: CLIENT_SECRET,
      code:          DataStorage[:google_nest_code],
      grant_type:    "authorization_code",
      redirect_uri:  REDIRECT_URI,
    }

    res = RestClient.post("https://www.googleapis.com/oauth2/v4/token", params)
    json = JSON.parse(res.body).with_indifferent_access

    @refresh_token = DataStorage[:google_nest_refresh_token] = json[:refresh_token]
    @access_token = DataStorage[:google_nest_access_token] = "#{json[:token_type]} #{json[:access_token]}"
  end

  def request_or_refresh(&block)
    refreshed = false
    begin
      block.call
    rescue => e
      refresh
      unless refreshed
        refreshed = true
        retry
      end
    end
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
