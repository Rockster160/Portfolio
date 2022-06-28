class Jarvis
  def self.command(user, words)
    new(user, words).command
  end

  def initialize(user, words)
    @user = user
    @words = words
  end

  def command
    parse_words
    unless @cmd.present?
      @cmd, @args = @words.squish.downcase.split(" ", 2)
    end

    case @cmd.to_s.to_sym
    when :car
      return "Sorry, you can't do that." unless @user.admin?

      car_cmd, car_params = @args.split(" ", 2)

      TeslaCommandWorker.perform_async(car_cmd, car_params)

      car_response(car_cmd, car_params) || "Not sure how to tell car: #{car_cmd}"
    when :fn
      return "Sorry, you can't do that." unless @user.admin?

      CommandControl.parse(@words)
    when :open
      ["Opening #{@args}", { open: @args }]
    when :list
      List.find_and_modify(@user, @args)
    else
      SmsMoney.parse(@user, @words)
    end
  end

  def shortcut
    return @shortcut if defined?(@shortcut)

    return @shortcut = nil unless @user.admin?
    @shortcut = begin
      jarvis_shortcuts = DataStorage[:jarvis_shortcuts] ||= {}
      found = jarvis_shortcuts.find { |key, val|
        next true if @words == key
        @words.gsub(/\b(the|my|set|to)\b/, "").squish == key
      }&.dig(1) # Get the value
      # How would this work for "Remind me to X in 30 minutes" -> Send text delayed for 30 mins

      # Maybe use DataStorage to save preset commands
      # Many of these could even run other functions, such as formatting data
    end
  end

  def parse_words
    token = SecureRandom.hex(3)
    return shortcut if shortcut
    return parse_list_words if @words.downcase.squish.match?(/^(add|remove)/)
    return parse_car_words if @words.downcase.include?("car")
    # Also allow for timed things, such as "Start my car in 20 minutes", "Remind me to leave in 20 minutes<sends SMS>", etc....
  end

  def parse_list_words
    @cmd = :list
    # Could probably move all of the word parsing logic into here rather than the model
    @args = @words
  end

  # Should probably extract these to a different file jarvis/car

  def car_response(cmd, prms)
    case cmd.to_s.to_sym
    when :update, :reload
      "Updating car cell"
    when :off, :stop
      "Stopping car"
    when :on, :start
      "Starting car"
    when :boot, :trunk
      if prms == "close"
        "Closing the boot"
      else
        "Popping the boot"
      end
    when :lock
      "Locking car doors"
    when :unlock
      "Unlocking car doors"
    when :doors, :door
      if prms.in?(["lock", "close"])
        "Locking car doors"
      else
        "Unlocking car doors"
      end
    when :windows, :window
      if prms.in?(["close"])
        "Closing car windows"
      else
        "Opening car windows"
      end
    when :frunk
      "Opening frunk"
    when :temp
      "Car temp set to #{prms}"
    when :cool
      "Car temp set to 59"
    when :heat
      "Car temp set to 82 and seat heaters turned on"
    else
      "Car temp set to #{cmd}" if cmd.to_s.to_i.to_s == cmd.to_s
    end
  end

  def car_commands
    [
      :update,
      :reload,
      :off,
      :stop,
      :on,
      :start,
      :boot,
      :trunk,
      :lock,
      :unlock,
      :doors,
      :door,
      :windows,
      :window,
      :frunk,
      :temp,
      :cool,
      :heat,
    ]
  end

  def parse_car_words
    @cmd = :car

    @args = @words
    if @args.match?(/(the|my) (\w+)$/)
      end_word = @args[/\w+$/]
      @args[/(the|my) (\w+)$/] = ""
      @args = "#{end_word} #{@args}"
    end

    @args = @args.gsub(/ ?\b(car)\b ?/, ' ').squish

    if @args.match?(/^\b(open)\b/)
      @args[/^\b(open)\b/] = ""
      @args = "#{@args} open"
    end

    @args.gsub!(Regexp.new("(.+)\\b(#{car_commands.join('|')})\\b")) do |found|
      "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
    end

    @args.gsub!(/\b(the|set|to)\b/, "")
    @args.gsub!(/\bstart\b/, "on")
    @args = @args.squish
  end
end
