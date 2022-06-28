class Jarvis
  def self.command(user, words)
    new(user, words).command
  end

  def initialize(user, words)
    @user = user
    @words = words.to_s.downcase
  end

  def command
    return "Sorry, I don't know who you are." unless @user.present?

    parse_words
    unless @cmd.present?
      @cmd, @args = @words.squish.downcase.split(" ", 2)
    end

    case @cmd.to_s.to_sym
    when :car
      return "Sorry, you can't do that." unless @user.admin?

      car_cmd, car_params = @args.split(" ", 2)

      # TeslaCommandWorker.perform_async(car_cmd, car_params)

      car_response(car_cmd, car_params) || "Not sure how to tell car: #{car_cmd}"
    when :fn, :run
      return "Sorry, you can't do that." unless @user.admin?

      CommandControl.parse(@words)
    when :log
      return "Sorry, you can't do that." unless @user.admin?

      evt, data = @args.split(" ", 2)
      split = data.to_s.split(/\bat /)
      notes, timestamp = split.length > 1 ? [split[0..-2], split.last] : [split, nil]

      notes = notes.join(" at ").squish
      parsed_time = safe_date_parse(timestamp)
      notes += " at #{timestamp}" if timestamp.present? && parsed_time.blank?

      evt_data = {
        event_name: evt.capitalize,
        notes: notes.presence,
        timestamp: parsed_time.presence,
        user_id: @user.id,
      }.compact

      evt = ActionEvent.create(evt_data)

      if evt.persisted?
        ActionEventBroadcastWorker.perform_async(evt.id)
        evt_words = ["Logged #{evt.event_name}"]
        evt_words << "(#{evt.notes})" if evt.notes.present?
        evt_words << "[#{evt.timestamp.to_formatted_s(:short_with_time)}]" if parsed_time.present?
        evt_words.join(" ")
      else
        evt.errors.full_messages.join("\n")
      end
    when :open
      ["Opening #{@args}", { open: @args }]
    when :list
      List.find_and_modify(@user, @args)
    when :budget
      SmsMoney.parse(@user, @words)
    when :scheduled
      @args
    else
      # Respond to things like hello, are you there, etc....
      "Unknown command <#{[@cmd, @args.presence].compact.join(': ')}>"
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
    simple_words = @words.downcase.squish
    return parse_log_words if simple_words.match?(/^log\b/)
    # Logs have their own timestamp, so run them before checking for delayed commands
    return schedule_command if should_schedule?(simple_words)

    return shortcut if shortcut
    return parse_list_words if simple_words.match?(/^(add|remove)\b/)
    return parse_car_words if simple_words.include?("car")

    if simple_words.split(" ", 2).first.in?([:car, :fn, :run, :log, :open, :list])
      return # Let the main splitter break things up
    end

    if simple_words.match?(Regexp.new("\\b(#{car_commands.join('|')})\\b"))
      return parse_car_words
    end

    found_command = matches_command?(simple_words)
    return parse_command(found_command) if found_command

    if simple_words.match?(Regexp.new("\\b(#{@user.lists.pluck(:name).join('|')})\\b"))
      return parse_list_words
    end
  end

  def should_schedule?(simple_words)
    day_words = (Date::DAYNAMES + Date::ABBR_DAYNAMES + [:today, :tomorrow, :yesterday]).map { |w| w.to_s.downcase.to_sym }
    day_words_regex = Regexp.new("\\b(#{day_words.join('|')})\\b")
    time_words = [:second, :minute, :hour, :day, :week, :month]
    time_words_regex = Regexp.new("\\b(#{time_words.join('|')})s?\\b")
    time_str = simple_words[/\b(in) \d+ #{time_words_regex}/]
    time_str ||= simple_words[/(#{day_words_regex} )?\b(at) \d+:?\d*( ?(am|pm))?( #{day_words_regex})?/]
    time_str ||= simple_words[/\d+ #{time_words_regex} from now/]
    time_str ||= simple_words[/(next )?#{day_words_regex}/]

    @scheduled_time = safe_date_parse(time_str.to_s.gsub(/ ?\b(at)\b ?/, " ").squish)
    @remaining_words = @words.sub(Regexp.new(time_str, "i"), "").squish if @scheduled_time

    @scheduled_time.present?
  end

  def schedule_command
    JarvisWorker.perform_at(@scheduled_time, @user.id, @remaining_words)
    @cmd = :scheduled
    @args = "I'll #{@remaining_words.gsub(/\b(my)\b/, 'your')} later at #{@scheduled_time.to_formatted_s(:quick_week_time)}"
  end

  def matches_command?(simple_words)
    return false unless @user.admin?

    command = CommandProposal::Task.find_by("? ILIKE CONCAT(friendly_id, '%')", simple_words)
    command ||= CommandProposal::Task.find_by("? ILIKE CONCAT(REGEXP_REPLACE(friendly_id, '[^a-z]', '', 'i'), '%')", simple_words.gsub(/[^a-z]/i, ""))
  end

  def parse_command(found_command)
    @cmd = :fn

    # Should do something about spaces instead of _ as well
    without_name = @words.gsub(Regexp.new("\\b(#{found_command.friendly_id})\\b"), "")
    @args = "#{found_command.friendly_id} #{without_name}"
  end

  def safe_date_parse(timestamp)
    Time.zone = "Mountain Time (US & Canada)"
    Chronic.time_class = Time.zone
    Chronic.parse(timestamp)
  end

  def parse_list_words
    @cmd = :list
    # Could probably move all of the word parsing logic into here rather than the model
    @args = @words
  end

  def parse_log_words
    @cmd = :log
    @args = @words.gsub(/^log ?/i, "")
  end

  # Should probably extract these to a different file jarvis/car

  def car_response(cmd, prms)
    case cmd.to_s.downcase.to_sym
    when :update, :reload
      "Updating car cell"
    when :off, :stop
      "Stopping car"
    when :on, :start
      "Starting car"
    when :boot, :trunk
      if prms&.match?(/\b(close)\b/)
        "Closing the boot"
      else
        "Popping the boot"
      end
    when :lock
      "Locking car doors"
    when :unlock
      "Unlocking car doors"
    when :doors, :door
      if prms&.match?(/\b(lock|close)\b/)
        "Locking car doors"
      else
        "Unlocking car doors"
      end
    when :windows, :window
      if prms&.match?(/\b(close)\b/)
        "Closing car windows"
      else
        "Opening car windows"
      end
    when :frunk
      "Opening frunk"
    when :temp
      "Car temp set to #{prms}"
    when :cool, :cold
      "Car temp set to 59"
    when :heat, :warm
      "Car temp set to 82 and seat heaters turned on"
    when :find
      "Finding your car..."
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
      :warm,
      :find,
      :where,
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
    @args = @args.gsub(/where\'?s?( is)?/, "find")

    if @args.match?(/^\b(open)\b/)
      @args[/^\b(open)\b/] = ""
      @args = "#{@args} open"
    end

    @args.gsub!(Regexp.new("(.+)\\b(#{car_commands.join('|')})\\b")) do |found|
      "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
    end

    @args.gsub!(/\b(the|set|to|is)\b/, "")
    @args.gsub!(/\b(start)\b/, "on")
    @args = @args.squish
  end
end
