class TeslaCommandWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(cmd, params=nil)
    ActionCable.server.broadcast("tesla_channel", { loading: true })
    car = Tesla.new

    cmd = cmd.to_s.downcase.squish
    params = params.to_s.downcase.squish
    direction = :toggle
    if "#{cmd} #{params}".match?(/\b(open|close|pop|vent)\b/)
      combine = "#{cmd} #{params}"
      direction = :open if combine.match?(/\b(open|pop)\b/)
      direction = :close if combine.match?(/\b(close)\b/)
      cmd, params = combine.gsub(/\b(open|close|pop)\b/, "").squish.split(" ", 2)
    elsif cmd.to_i.to_s == cmd
      params = cmd.to_i
      cmd = :temp
    end

    case cmd.to_sym
    when :update, :reload
      return ActionCable.server.broadcast "tesla_channel", format_data(car.data)
    when :off, :stop
      car.off
    when :on, :start
      car.on
    when :boot, :trunk
      car.pop_boot(direction)
    when :lock
      car.doors(:close)
    when :unlock
      car.doors(:open)
    when :doors, :door
      car.doors(direction)
    when :windows, :window
      car.windows(direction)
    when :frunk
      car.pop_frunk
    when :temp
      temp = 82 if params.match?(/\b(hot|heat|high)\b/)
      temp = 59 if params.match?(/\b(cold|cool|low)\b/)
      car.set_temp(params.to_i)
    when :cool
      car.set_temp(59)
    when :heat
      car.set_temp(82)
      car.heat_driver
      car.heat_passenger
    end

    sleep 3 # Give the API a chance to update
    ActionCable.server.broadcast("tesla_channel", format_data(car.data))
  rescue StandardError => e
    SlackNotifier.notify("Failed to command: #{e.inspect}")
  end

  def cToF(c)
    (c * (9/5.to_f)).round + 32
  end

  def format_data(data)
    {
      charge: data.dig(:charge_state, :battery_level),
      miles: data.dig(:charge_state, :battery_range)&.floor,
      charging: {
        active: data.dig(:charge_state, :charging_state) != "Complete", # FIXME
        speed: data.dig(:charge_state, :charge_rate),
        eta: data.dig(:charge_state, :minutes_to_full_charge),
      },
      climate: {
        on: data.dig(:climate_state, :is_climate_on),
        set: cToF(data.dig(:climate_state, :driver_temp_setting)),
        current: cToF(data.dig(:climate_state, :inside_temp)),
      },
      open: {
        ft:        data.dig(:vehicle_state, :ft), # Frunk
        df:        data.dig(:vehicle_state, :df), # Driver Door
        fd_window: data.dig(:vehicle_state, :fd_window), # Driver Window
        pf:        data.dig(:vehicle_state, :pf), # Passenger Door
        fp_window: data.dig(:vehicle_state, :fp_window), # Passenger Window
        dr:        data.dig(:vehicle_state, :dr), # Rear Driver Door
        rd_window: data.dig(:vehicle_state, :rd_window), # Rear Driver Window
        pr:        data.dig(:vehicle_state, :pr), # Rear Passenger Door
        rp_window: data.dig(:vehicle_state, :rp_window), # Rear Passenger Window
        rt:        data.dig(:vehicle_state, :rt), # Trunk
      },
      locked: data.dig(:vehicle_state, :locked),
      drive: drive_data(data).merge(speed: data.dig(:drive_state, :speed).to_i),
      timestamp: data.dig(:vehicle_config, :timestamp) / 1000
    }
  end

  def drive_data(data)
    loc = [data.dig(:drive_state, :latitude), data.dig(:drive_state, :longitude)]
    speed = data.dig(:drive_state, :speed).to_i > 0

    place = near(loc)
    action = speed ? :Near : :At
    return { action: action, location: place[0] } if place

    action = speed ? :Driving : :Stopped
    city = reverse_geocode(loc) if loc.compact.length == 2
    return { action: action, location: city } if city

    { action: action, location: "<Unknown>" }
  end

  def reverse_geocode(loc)
    url = "https://maps.googleapis.com/maps/api/geocode/json?latlng=#{loc.join(",")}&key=#{ENV["PORTFOLIO_GMAPS_PAID_KEY"]}"
    res = RestClient.get(url)
    json = JSON.parse(res.body, symbolize_names: true)
    json.dig(:results, 0, :address_components)&.find { |comp|
      comp[:types] == ["locality", "political"]
    }&.dig(:short_name)
  end

  def distance(c1, c2)
    # √[(x₂ - x₁)² + (y₂ - y₁)²]
    Math.sqrt((c2[0] - c1[0])**2 + (c2[1] - c1[1])**2)
  end

  def near(loc)
    places.find { |name, coord| distance(coord, loc) <= 0.001 }
  end

  def places
    {
      "Home":       [40.480397533491380, -111.99813671577154],
      "B's":        [40.479102753787934, -111.99827125324934],
      "PT":         [40.529137812652580, -111.85281503864579],
      "Home Depot": [40.510199316274665, -111.98287918290242],
      "Lowe's":     [40.524773389671120, -111.98219609144238],
      "Bowling":    [40.523552559740600, -111.97905149726870],
      "Walmart":    [40.506277043465650, -111.97889518732400],
      "Harmon's":   [40.508948110252156, -112.00113553075886],
      "Costco":     [40.513301237988970, -112.00187873309916],
      "Rich's":     [40.665129778039770, -111.95385943760118],
      "Doug's":     [40.475594135832644, -111.92496882799394],
      "Wil's":      [40.606558473360530, -111.84936827661250],
    }
  end
end
