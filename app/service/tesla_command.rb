class TeslaCommand
  def self.command(cmd, params=nil)
    new.command(cmd, params)
  end

  def command(cmd, params=nil)
    if Rails.env.development?
      ActionCable.server.broadcast "tesla_channel", stubbed_data
      return "Stubbed data"
    end

    ActionCable.server.broadcast("tesla_channel", loading: true)
    car = Tesla.new

    cmd = cmd.to_s.downcase.squish
    params = params.to_s.downcase.squish
    direction = :toggle
    if "#{cmd} #{params}".match?(/\b(unlock|open|lock|close|pop|vent)\b/)
      combine = "#{cmd} #{params}"
      direction = :open if combine.match?(/\b(unlock|open|pop)\b/)
      direction = :close if combine.match?(/\b(lock|close)\b/)
      cmd, params = combine.gsub(/\b(open|close|pop)\b/, "").squish.split(" ", 2)
    elsif cmd.to_i.to_s == cmd
      params = cmd.to_i
      cmd = :temp
    end

    case cmd.to_sym
    when :update, :reload
      @response = "Updating car cell"
      return ActionCable.server.broadcast "tesla_channel", format_data(car.vehicle_data)
    when :off, :stop
      @response = "Stopping car"
      car.off_car
    when :on, :start, :climate
      @response = "Starting car"
      car.start_car
    when :boot, :trunk
      @response = "Popping the boot"
      car.pop_boot(direction)
    when :lock
      @response = "Locking car doors"
      car.doors(:close)
    when :unlock
      @response = "Unlocking car doors"
      car.doors(:open)
    when :doors, :door
      if direction == :open
        @response = "Unlocking car doors"
      else
        @response = "Locking car doors"
      end
      car.doors(direction)
    when :windows, :window, :vent
      if direction == :open
        @response = "Opening car windows"
      else
        @response = "Closing car windows"
      end
      car.windows(direction)
    when :frunk
      @response = "Opening frunk"
      car.pop_frunk
    when :honk, :horn
      @response = "Honking the horn"
      car.honk
    when :navigate
      @response = "Navigating to #{params}"
      car.navigate(params)
    when :temp
      temp = 82 if params.to_s.match?(/\b(hot|heat|high)\b/)
      temp = 59 if params.to_s.match?(/\b(cold|cool|low)\b/)
      @response = "Car temp set to #{params.to_i}"
      car.set_temp(params.to_i)
    when :cool
      @response = "Car temp set to 59"
      car.set_temp(59)
    when :heat, :defrost, :warm
      @response = "Defrosting the car"
      car.set_temp(82)
      car.heat_driver
      car.heat_passenger
      car.defrost
    when :find
      @response = "Finding car..."
      data = car.vehicle_data
      loc = [data.dig(:drive_state, :latitude), data.dig(:drive_state, :longitude)]
      Jarvis.say("http://maps.apple.com/?ll=#{loc.join(',')}&q=#{loc.join(',')}", :sms)
    else
      @response = "Not sure how to tell car: #{[cmd, params].map(&:presence).join('|')}"
    end

    @response
  rescue StandardError => e
    ActionCable.server.broadcast("tesla_channel", failed: true)
    backtrace = e.backtrace&.map {|l|l.include?('app') ? l.gsub("`", "'") : nil}.compact.join("\n")
    SlackNotifier.notify("Failed to command: #{e.inspect}\n#{backtrace}")
    raise e # Re-raise to stop worker from sleeping and attempting to re-get
  end

  def cToF(c)
    return unless c
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
      timestamp: data.dig(:vehicle_config, :timestamp).to_i / 1000
    }
  end

  def stubbed_data
    {
      charge: 77,
      miles: 194,
      charging: {
        active: true,
        speed: 34.4,
        eta: 35,
      },
      climate: {
        on: true,
        set: 69,
        current: 70,
      },
      open: {
        ft:        false, # Frunk
        df:        false, # Driver Door
        fd_window: true, # Driver Window
        pf:        false, # Passenger Door
        fp_window: false, # Passenger Window
        dr:        false, # Rear Driver Door
        rd_window: false, # Rear Driver Window
        pr:        false, # Rear Passenger Door
        rp_window: false, # Rear Passenger Window
        rt:        true, # Trunk
      },
      locked: true,
      drive: {
        action: ["Driving", "Near", "At", "Stopped"].sample,
        location: places.keys.sample,
        speed: 0,
      },
      timestamp: Time.current.to_i
    }
  end

  def drive_data(data)
    loc = [data.dig(:drive_state, :latitude), data.dig(:drive_state, :longitude)]
    is_driving = data.dig(:drive_state, :speed).to_i > 0

    place = near(loc)
    action = is_driving ? :Near : :At
    return { action: action, location: place[0] } if place

    action = is_driving ? :Driving : :Stopped
    city = reverse_geocode(loc) if loc.compact.length == 2
    return { action: action, location: city } if city

    { action: action, location: "<Unknown>" }
  end

  def reverse_geocode(loc)
    return "Herriman" unless Rails.env.production?

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
    return [] unless loc.compact.length == 2
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
