module PrinterAPI
  module_function

  BASE_HEADERS = {
    "User-Agent": "PortfolioBot/1.0",
    "Content-Type": "application/json",
    "Authorization": "Basic #{Base64.encode64("Rockster160:#{DataStorage[:printer_password]}")}",
  }

  def update_ngrok(base_url)
    DataStorage[:printer_needs_reset] = false
    DataStorage[:printer_ngrok_base_url] = base_url
  end

  def extrude(amount)
    tool(:extrude, amount: amount.to_f)
  end

  def extrude(amount)
    tool(:extrude, amount: -amount.to_f)
  end

  def home
    post(:printhead, command: :home, axes: [:x, :y, :z])
  end

  def move(coords)
    if coords.is_a?(String)
      coords = [:x, :y, :z].each_with_object({}) do |axis, obj|
        obj[axis] = coords.match(/#{axis}:? (\-?\d+)/i).to_a[1].to_i.presence
      end
    end

    # coords are x, y, z hash with pos/neg values
    post(:printhead, command: :jog, **coords.compact)
  end

  def cool
    tool(:target, targets: { tool0: 0 })
    bed(:target, targets: 0)
  end

  def pre
    on
    sleep 1
    tool_temp(200)
    bed_temp(40)
  end

  def tool_temp(new_temp)
    tool(:target, targets: { tool0: new_temp })
  end

  def bed_temp(new_temp)
    bed(:target, targets: new_temp)
  end

  def printer
    get
  end

  def job
    get(:job)
  end

  def on
    command(:M80)
  end

  def off
    command(:M81)
  end

  def command(gcode)
    codes = gcode.to_s.split(/, ?/)
    post(:command, commands: codes) if codes.many?
    post(:command, command: codes.first) if codes.one?
  end

  def tool(cmd, opts={})
    post(:tool, command: cmd, **opts)
  end

  def bed(cmd, opts={})
    post(:bed, command: cmd, **opts)
  end

  def get(endpoint=nil)
    raise "Should not GET in tests!" if Rails.env.test?

    res = RestClient.get(
      [
        DataStorage[:printer_ngrok_base_url],
        :api,
        (endpoint == :job ? nil : :printer),
        endpoint.presence
      ].compact.join("/"),
      BASE_HEADERS
    )

    JSON.parse(res.body, symbolize_names: true)
  rescue RestClient::Exception => err
    if !DataStorage[:printer_needs_reset]
      SlackNotifier.notify("Failed to request from PrinterControl#get(#{endpoint}):\nErr: #{err}\n```#{err.message}```")
    end
    DataStorage[:printer_needs_reset] = true
    {}
  rescue JSON::ParserError => err
    if !DataStorage[:printer_needs_reset]
      SlackNotifier.notify("Failed to parse json from PrinterControl#get(#{endpoint}):\nCode: #{res.code}\n```#{res.body}```")
    end
    DataStorage[:printer_needs_reset] = true
    {}
  end

  def post(endpoint, params={})
    raise "Should not POST in tests!" if Rails.env.test?

    res = RestClient.post(
      "#{DataStorage[:printer_ngrok_base_url]}/api/printer/#{endpoint}",
      params.to_json,
      BASE_HEADERS
    )

    return {} if res.code == 204
    JSON.parse(res.body, symbolize_names: true)
  rescue RestClient::Exception => err
    if !DataStorage[:printer_needs_reset]
      SlackNotifier.notify("Failed to request from PrinterControl#post(#{endpoint}, #{params}):\nErr: #{err}\n```#{err.message}```")
    end
    DataStorage[:printer_needs_reset] = true
    {}
  rescue JSON::ParserError => err
    if !DataStorage[:printer_needs_reset]
      SlackNotifier.notify("Failed to parse json from PrinterControl#post(#{endpoint}, #{params}):\nCode: #{res.code}\n```#{res.body}```")
    end
    DataStorage[:printer_needs_reset] = true
    {}
  end
end
