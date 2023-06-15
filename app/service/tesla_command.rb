 class TeslaCommand
   include ActionView::Helpers::DateHelper
   TEMP_MIN = 59
   TEMP_MAX = 82

  def self.command(cmd, opt=nil, quick=false)
    new.command(cmd, opt, quick)
  end

  def self.quick_command(cmd, opt=nil)
    return "Currently forbidden" if DataStorage[:tesla_forbidden]

    TeslaCommandWorker.perform_async(cmd.to_s, opt&.to_s)
    command(cmd, opt, true)
  end

  def address_book
    @address_book ||= User.admin.first.address_book
  end

  def command(original_cmd, original_opt=nil, quick=false)
    if Rails.env.development?
      ActionCable.server.broadcast(:tesla_channel, stubbed_data)
      return "Stubbed data"
    end

    ActionCable.server.broadcast(:tesla_channel, { loading: true })
    car = Tesla.new unless quick

    cmd = original_cmd.to_s.downcase.squish
    opt = original_opt.to_s.downcase.squish
    direction = :toggle
    if "#{cmd} #{opt}".match?(/\b(unlock|open|lock|close|pop|vent)\b/)
      combine = "#{cmd} #{opt}"
      direction = :open if combine.match?(/\b(unlock|open|pop)\b/)
      direction = :close if combine.match?(/\b(lock|close|shut)\b/)
      cmd, opt = combine.gsub(/\b(open|close|pop)\b/, "").squish.split(" ", 2)
    elsif cmd.to_i.to_s == cmd
      opt = cmd.to_i
      cmd = :temp
    end

    case cmd.to_sym
    when :request
      ActionCable.server.broadcast(:tesla_channel, format_data(Tesla.new.cached_vehicle_data))
    when :update, :reload
      ActionCable.server.broadcast(:tesla_channel, format_data(car.vehicle_data)) unless quick
      @response = "Updating car cell"
      return @response
    when :off, :stop
      @response = "Stopping car"
      car.off_car unless quick
    when :on, :start, :climate
      @response = "Starting car"
      car.start_car unless quick
    when :boot, :trunk
      dir = "Closing" if direction == :close
      @response = "#{dir || "Popping"} the boot"
      car.pop_boot(direction) unless quick
    when :lock
      @response = "Locking car doors"
      car.doors(:close) unless quick
    when :unlock
      @response = "Unlocking car doors"
      car.doors(:open) unless quick
    when :doors, :door
      if direction == :open
        @response = "Unlocking car doors"
      else
        @response = "Locking car doors"
      end
      car.doors(direction) unless quick
    when :windows, :window, :vent
      if direction == :open
        @response = "Opening car windows"
      else
        @response = "Closing car windows"
      end
      car.windows(direction) unless quick
    when :frunk
      @response = "Opening frunk"
      car.pop_frunk unless quick
    when :honk, :horn
      @response = "Honking the horn"
      car.honk unless quick
    when :seat
      @response = "Turning on driver seat heater"
      car.heat_driver unless quick
    when :passenger
      @response = "Turning on passenger seat heater"
      car.heat_passenger unless quick
    when :navigate
      address = opt[::Jarvis::Regex.address]&.squish.presence if opt.match?(::Jarvis::Regex.address)
      address ||= address_book.contact_by_name(original_opt)&.address
      address ||= address_book.nearest_address_from_name(original_opt)

      if address.present?
        duration = address_book.traveltime_seconds(address)
        if duration
          @response = "It will take #{distance_of_time_in_words(duration)} to get to #{original_opt.squish}"
        else
          @response = "Navigating to #{original_opt.squish}"
        end

        unless quick
          car.start_car
          car.navigate(address)
        end
      else
        @response = "I can't find #{original_opt.squish}"
      end
    when :temp
      temp = opt.to_s[/\d+/]
      temp = TEMP_MAX if opt.to_s.match?(/\b(hot|heat|high)\b/)
      temp = TEMP_MIN if opt.to_s.match?(/\b(cold|cool|low)\b/)
      @response = "Car temp set to #{temp.to_i}"
      car.set_temp(temp.to_i) unless quick
    when :cool
      @response = "Car temp set to #{TEMP_MIN}"
      car.set_temp(TEMP_MIN) unless quick
    when :heat, :defrost, :warm
      @response = "Defrosting the car"
      unless quick
        car.set_temp(TEMP_MAX)
        car.heat_driver
        car.heat_passenger
        car.defrost
      end
    when :find
      @response = "Finding car..."
      unless quick
        data = car.vehicle_data
        loc = [data.dig(:drive_state, :latitude), data.dig(:drive_state, :longitude)]
        Jarvis.say("http://maps.apple.com/?ll=#{loc.join(',')}&q=#{loc.join(',')}", :sms)
      end
    else
      @response = "Not sure how to tell car: #{[cmd, opt].map(&:presence).compact.join('|')}"
    end

    @response
  rescue TeslaError => e
    if e.message.match?(/forbidden/i)
      ActionCable.server.broadcast(:tesla_channel, format_data(Tesla.new.cached_vehicle_data))
    else
      ActionCable.server.broadcast(:tesla_channel, { failed: true })
    end
    "Tesla #{e.message}"
  rescue StandardError => e
    ActionCable.server.broadcast(:tesla_channel, { failed: true })
    backtrace = e.backtrace&.map {|l|l.include?('app') ? l.gsub("`", "'") : nil}.compact.join("\n")
    SlackNotifier.notify("Failed to command: #{e.inspect}\n#{backtrace}")
    raise e # Re-raise to stop worker from sleeping and attempting to re-get
    "Failed to request from Tesla"
  end

  def cToF(c)
    return unless c
    (c * (9/5.to_f)).round + 32
  end

  def format_data(data)
    return {} if data.blank?

    {
      forbidden: DataStorage[:tesla_forbidden],
      charge: data.dig(:charge_state, :battery_level),
      miles: data.dig(:charge_state, :battery_range)&.floor,
      charging: {
        state: data.dig(:charge_state, :charging_state),
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
      forbidden: false,
      charge: 100,
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
        location: address_book.contacts.pluck(:name).sample,
        speed: 0,
      },
      timestamp: Time.current.to_i
    }
  end

  def drive_data(data)
    loc = [data.dig(:drive_state, :latitude), data.dig(:drive_state, :longitude)]
    is_driving = data.dig(:drive_state, :speed).to_i > 0

    place = address_book.near(loc)
    action = is_driving ? :Near : :At
    return { action: action, location: place[:name] } if place.present?

    action = is_driving ? :Driving : :Stopped
    city = address_book.reverse_geocode(loc) if loc.compact.length == 2
    return { action: action, location: city } if city.present?

    { action: action, location: "<Unknown>" }
  end
end
