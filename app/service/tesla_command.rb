module TeslaCommand
  module_function
  extend ActionView::Helpers::DateHelper

  TEMP_MIN = 59
  TEMP_MAX = 82

  def quick_command(cmd, opt=nil)
    return "Currently forbidden" if DataStorage[:tesla_forbidden]

    command(cmd, opt, true)
  end

  def broadcast(extra_data={})
    ActionCable.server.broadcast(:tesla_channel, format_data(extra_data))
  end

  def address_book
    @address_book ||= User.me.address_book
  end

  def command(original_cmd, original_opt=nil, quick=false)
    ::PrettyLogger.info("command (quick #{quick})")
    broadcast(loading: true)
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
    elsif cmd.match?(/\bcar\b/)
      cmd = opt
    end

    case cmd.to_sym
    when :reload # Wake up car and get current data
      broadcast(car.vehicle_data(wake: true)) unless quick
      @response = "Updating car cell"
      return @response
    when :request # Get cached car data
      broadcast
    when :update # Get current data, but do not wake up
      broadcast(car.vehicle_data) unless quick
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
      # gps = address_book.geocode(address) if address.present?
      # If specify nearest, search based on car location.
      # Otherwise use the one in contacts and fallback to nearest to house
      address ||= address_book.contact_by_name(original_opt)&.primary_address&.street
      address ||= address_book.nearest_from_name(original_opt, extract: :address)

      if address.present?
        duration = address_book.traveltime_seconds(address)
        if duration && duration < 100 # seconds
          @cancel = true
          @response = "You're already at your destination."
        elsif duration
          @response = "It will take #{distance_of_time_in_words(duration)} to get to #{original_opt.squish}"
        else
          @response = "Navigating to #{original_opt.squish}"
        end

        ::PrettyLogger.info("!@cancel && !quick == #{!@cancel} && #{!quick}")
        if !@cancel && !quick
          ::PrettyLogger.info("starting")
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
        loc = TeslaControl.me.loc
        Jarvis.say("http://maps.apple.com/?ll=#{loc.join(',')}&q=#{loc.join(',')}", :sms)
      end
    else
      @response = "Not sure how to tell car: #{[cmd, opt].map(&:presence).compact.join('|')}"
    end

    res = @response # Local variable since modules share ivars
    Jarvis.ping(@response) unless quick
    TeslaCommandWorker.perform_async(cmd.to_s, opt&.to_s) if quick && !@cancel
    @cancel = false
    res
  rescue TeslaError => e
    if e.message.match?(/forbidden/i)
      broadcast
    else
      broadcast(failed: true)
    end
    "Tesla #{e.message}"
  rescue StandardError => e
    broadcast(failed: true)
    backtrace = e.backtrace.map { |l|
      l.include?("/app/") ? l.gsub("`", "'").gsub(/^.*\/app\//, "") : nil
    }.compact.join("\n").truncate(2000)
    SlackNotifier.notify("Failed to command: #{e.inspect}\n```\n#{backtrace}\n```")
    raise e # Re-raise to stop worker from sleeping and attempting to re-get
    "Failed to request from Tesla"
  end

  def cToF(c)
    return unless c
    (c * (9/5.to_f)).round + 32
  end

  def format_data(extra_data={})
    data = Tesla.new.cached_vehicle_data.merge(extra_data)

    return {} if data.blank?
    return data if data[:charge_state].blank?

    {
      forbidden: DataStorage[:tesla_forbidden],
      loading: !!data[:loading],
      sleeping: data[:state] == "asleep" || !!data[:sleeping],
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
      loc: [
        data.dig(:drive_state, :latitude),
        data.dig(:drive_state, :longitude),
      ],
      timestamp: data.dig(:timestamp).to_i / 1000
    }
  end

  def drive_data(data)
    loc = [
      data.dig(:drive_state, :latitude),
      data.dig(:drive_state, :longitude),
    ]
    is_driving = data.dig(:drive_state, :speed).to_i > 0

    place = address_book.find_contact_near(loc)
    action = is_driving ? :Near : :At
    return { action: action, location: place[:name] } if place.present?

    action = is_driving ? :Driving : :Stopped
    city = address_book.reverse_geocode(loc, get: is_driving ? :city : :name) if loc.compact.length == 2
    return { action: action, location: city } if city.present?

    { action: action, location: loc.compact.map { |v| v&.round(2) }&.join(",").presence || "<Unknown>" }
  end
end
