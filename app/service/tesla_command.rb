module TeslaCommand
  module_function

  extend ActionView::Helpers::DateHelper

  TEMP_MIN = 59
  TEMP_MAX = 82

  # Controls that take an on/off. When the switch word or "heat" comes last
  # ("sentry off", "seat heat"), it's parsed as the command, so the command is
  # handed back to the control named before it.
  SWITCHED = [:sentry, :charge, :charging, :port, :steering, :wheel, :seat, :passenger].freeze
  SWITCH_WORDS = [:on, :off, :start, :stop, :heat, :warm].freeze

  def quick_command(cmd, opt=nil)
    return "Currently forbidden" if DataStorage[:tesla_forbidden]

    command(cmd, opt, true)
  end

  def broadcast(extra_data={})
    ActionCable.server.broadcast(:tesla_channel, format_data(extra_data))
  end

  # Writing the flag and telling the dashboard are one act, so they live in one
  # method. The Tesla cell renders straight off the broadcast, which means a
  # flag written without one leaves it displaying state that stopped being true.
  # Clearing it used to lean on "the next broadcast" arriving from somewhere
  # else — fine inside a command, but recovery happens outside one, and then no
  # broadcast ever comes and the disconnect icon just stays put.
  def proxy_unreachable!(value, extra={})
    value = !!value
    changed = !!DataStorage[:tesla_proxy_unreachable] != value
    DataStorage[:tesla_proxy_unreachable] = value if changed
    broadcast(extra) if changed || extra.present?
  end

  # The last thing that went wrong talking to Tesla, held until a request gets
  # through again. Transient failures count: the dashboard shows the mark for as
  # long as the most recent attempt is the one that failed.
  def error!(message, extra={})
    message = message.presence&.to_s
    changed = DataStorage[:tesla_error] != message
    DataStorage[:tesla_error] = message if changed
    broadcast(extra) if changed || extra.present?
  end

  def address_book
    @address_book ||= User.me.address_book
  end

  def command(original_cmd, original_opt=nil, quick=false)
    # Reset module-level state at the start of every dispatch. Otherwise a
    # raised exception leaves `@cancel = true` from the previous call and
    # silently no-ops the next user command. `@response` is the message
    # eventually returned/Slacked; clearing it avoids stale carry-over.
    @cancel = false
    @response = nil
    ::PrettyLogger.info("command (quick #{quick})")
    broadcast(loading: true)
    car = Tesla.new unless quick

    cmd = original_cmd.to_s.downcase.squish
    opt = original_opt.to_s.downcase.squish
    direction = :toggle
    feature = opt.split.map(&:to_sym).find { |word| SWITCHED.include?(word) }
    cmd, opt = feature.to_s, "#{opt} #{cmd}" if feature && SWITCH_WORDS.include?(cmd.to_sym)
    switch = :toggle
    switch = :on if opt.match?(/\b(on|start|enable)\b/)
    switch = :off if opt.match?(/\b(off|stop|disable)\b/)

    if "#{cmd} #{opt}".match?(/\b(unlock|open|lock|close|shut|pop|vent)\b/)
      combine = "#{cmd} #{opt}"
      direction = :open if combine.match?(/\b(unlock|open|pop)\b/)
      direction = :close if combine.match?(/\b(lock|close|shut)\b/)
      cmd, opt = combine.gsub(/\b(open|close|shut|pop)\b/, "").squish.split(" ", 2)
      opt = opt.to_s
    elsif cmd.to_i.to_s == cmd
      opt = cmd.to_i
      cmd = :temp
    elsif cmd.match?(/\bcar\b/)
      cmd = opt
    end

    return "No command found" if cmd.blank?

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
    when :port
      dir = direction == :close ? :close : :open
      @response = "#{dir == :close ? "Closing" : "Opening"} the charge port"
      car.charge_port(dir) unless quick
    when :charge, :charging
      if opt.match?(/\bport\b/)
        dir = direction == :close ? :close : :open
        @response = "#{dir == :close ? "Closing" : "Opening"} the charge port"
        car.charge_port(dir) unless quick
      else
        dir = { on: :start, off: :stop, toggle: :toggle }[switch]
        @response = { start: "Starting", stop: "Stopping", toggle: "Toggling" }[dir] + " charging"
        car.charging(dir) unless quick
      end
    when :sentry
      on = switch != :off
      @response = "Turning sentry mode #{on ? "on" : "off"}"
      car.sentry(on) unless quick
    when :steering, :wheel
      on = switch != :off
      @response = "Turning steering wheel heat #{on ? "on" : "off"}"
      car.steering_heat(on) unless quick
    when :honk, :horn
      @response = "Honking the horn"
      car.honk unless quick
    when :seat, :passenger
      seat = cmd.to_sym == :passenger || opt.match?(/\bpassenger\b/) ? :passenger : :driver
      on = switch != :off
      @response = "Turning #{on ? "on" : "off"} #{seat} seat heater"
      car.seat_heat(seat, on ? 3 : 0) unless quick
    when :navigate
      # Resolution priority:
      #   1. Explicit address recognized by Jarvis::Regex (e.g. "1 Main St")
      #   2. Smart contact match (handles "Sarah", "Sarah's house", etc.)
      #   3. Fuzzy nearest-by-name fallback for things like landmarks
      address = opt[::Jarvis::Regex.address]&.squish.presence if opt.match?(::Jarvis::Regex.address)
      address ||= address_book.match_contact(original_opt)&.primary_address&.street
      address ||= address_book.nearest_from_name(original_opt, extract: :address)

      if address.present?
        duration = address_book.traveltime_seconds(address)
        if duration && duration < 100 # seconds
          @cancel = true
          @response = "You're already at your destination."
        elsif duration
          @response = "Navigating to #{original_opt.squish} — #{distance_of_time_in_words(duration)} away"
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
      # Parse priority: explicit number, then natural-language keywords,
      # then default to a sensible mid-range (72°F) if nothing was usable.
      # Previously this fell through as nil → 0 → clamped silently to 59
      # while reporting "Car temp set to 0" — wrong both ways.
      temp = opt.to_s[/\d+/]&.to_i
      temp = TEMP_MAX if opt.to_s.match?(/\b(hot|heat|high)\b/)
      temp = TEMP_MIN if opt.to_s.match?(/\b(cold|cool|low)\b/)
      temp ||= 72
      @response = "Car temp set to #{temp}"
      car.set_temp(temp) unless quick
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
        Jarvis.say("http://maps.apple.com/?ll=#{loc.join(",")}&q=#{loc.join(",")}", :sms)
      end
    else
      @response = "Not sure how to tell car: #{[cmd, opt].map(&:presence).compact.join("|")}"
    end

    res = @response # Local variable since modules share ivars
    # Say, not ping. A car command is either something the person just asked for
    # out loud or automation doing its job — neither is worth a push. Matches
    # how Jil::Methods::Tesla#announce already reports every command it sends.
    Jarvis.say(@response) unless quick
    # The worker parses the words again, so it gets them as they were said:
    # the parsed pair has already dropped "close" from "close the trunk".
    TeslaCommandWorker.perform_async(original_cmd.to_s, original_opt.to_s) if quick && !@cancel
    @cancel = false
    res
  rescue TeslaError => e
    if e.message.match?(/forbidden/i)
      broadcast
    else
      error!(e.message, loading: false)
    end
    "Tesla #{e.message}"
  rescue StandardError => e
    error!("#{e.class}: #{e.message}", loading: false)
    backtrace = e.backtrace.map { |l|
      l.include?("/app/") ? l.gsub("`", "'").gsub(/^.*\/app\//, "") : nil
    }.compact.join("\n").truncate(2000)
    SlackNotifier.notify(
      [
        TeslaErrorClassifier.slack_message(
          e,
          where:       "TeslaCommand##{cmd}",
          toggle_link: TeslaSwitch.toggle_link(:disable),
        ),
        "```\n#{backtrace}\n```",
      ].join("\n"),
    )
    raise e # Re-raise to stop worker from sleeping and attempting to re-get
    "Failed to request from Tesla"
  end

  # The broadcast IS the clean :car_data, plus a few ephemeral flags
  # (loading, error, forbidden, sleeping) that don't belong on the
  # persistent cache but the dashboard cell needs to render. Dashboard JS
  # reads car_data field paths directly — no Rails-side reshaping.
  def format_data(extra_data={})
    data = Tesla.new.cached_vehicle_data || {}
    return {} if data.blank?

    data.merge(extra_data.symbolize_keys).merge(
      forbidden:         DataStorage[:tesla_forbidden],
      sleeping:          data[:state] == "asleep" || !!extra_data[:sleeping],
      proxy_unreachable: !!DataStorage[:tesla_proxy_unreachable],
      error:             DataStorage[:tesla_error],
    )
  end
end
