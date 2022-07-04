# =============================== TODO ===============================
# Allow asking questions: What's my car temp? What's the house temp? etc...
# create a timer that sends a WS to Dashboard and starts a timer (or sms? How to determine which is which?)
# Ability to undo messages or logs
# If question that doesn't match others, google and read the first result?
# Pick random number, weather update...
# (do thing) tonight > schedule thing for 7pm
# (do thing) in the morning > schedule thing for 8am
# Able to schedule an event for "every day" -> For example, sending good morning text
# Eventually? Able to say, "Remind me when I get home to..."
# * This triggers a job that reschedules itself for distance from house - 5 minutes
# * When <5 minutes from house, trigger given action
# Eventually? "Let me know before any night that's going to be a hard freeze"
# Monitor phone location with FindMy API


# =============================== Desired examples ===============================
# get the car|house|home, how's the car, tell me about the car, give me the car
# is the car unlocked?
# is the AC on?
# What did I have for breakfast?
# > You had cereal this morning, sir.
# Good morning / greeting
# > Good morning, sir. The weather today is <>. You don't have anything scheduled after your morning meetings.
# Good afternoon
# > Good afternoon, sir. The weather for the rest of the day is <>. You don't have any more meetings scheduled.
# Good night
# > Good night, sir. The weather tomorrow is <>. You don't have anything scheduled after your morning meetings.
# > You'll need to leave for PT by 9:55


# =============================== Jarvis.js ===============================
# Able to remove items from history using live-key, which enumerates the list items.
# -## will remove that item from display
# Able to ignore some messages?
# Able to set rules to only show certain messages for a certain amount of time?


class Jarvis
  IM_HERE_RESPONSES = ["For you sir, always.", "At your service, sir.", "Yes, sir.", "Good --time--, sir"]
  APPRECIATE_RESPONSES = ["You're welcome, sir."]

  def self.command(user, words)
    res, res_data = new(user, words).command

    ActionCable.server.broadcast("jarvis_channel", say: res, data: res_data) if res.present?
    [res, res_data]
  end

  def self.say(msg, channel=:ws)
    case channel
    when :sms then SmsWorker.perform_async("3852599640", msg)
    when :ws then ActionCable.server.broadcast("jarvis_channel", say: msg)
    end
  end

  def self.send(data, channel=:ws)
    case channel
    when :sms then SmsWorker.perform_async("3852599640", data)
    when :ws then ActionCable.server.broadcast("jarvis_channel", data: data)
    end
  end

  def initialize(user, words)
    @user = user
    @words = words.to_s
    Time.zone = "Mountain Time (US & Canada)"
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

      TeslaCommandWorker.perform_async(car_cmd, car_params)

      car_response(car_cmd, car_params) || "Not sure how to tell car: #{car_cmd}"
    when :home
      return "Sorry, you can't do that." unless @user.admin?

      NestCommandWorker.perform_async(@args)

      home_response(@args) || "Not sure how to tell home: #{@args}"
    when :text
      return "Sorry, you can't do that." unless @user.admin?

      SmsWorker.perform_async("3852599640", @args)

      "Sending you a text saying: #{@args}"
    when :fn, :run
      return "Sorry, you can't do that." unless @user.admin?
      return "Sorry, couldn't find a function called #{@args}." if !@args.is_a?(Hash) || @args.dig(:fn).blank?

      CommandRunner.run(@user, @args[:fn], @args[:fn_args])
    when :log
      return "Sorry, you can't do that." unless @user.admin?

      evt_data = {
        event_name: @args[:event_name].capitalize,
        notes: @args[:notes].presence,
        timestamp: @args[:timestamp].presence,
        user_id: @user.id,
      }.compact

      evt = ActionEvent.create(evt_data)

      if evt.persisted?
        ActionEventBroadcastWorker.perform_async(evt.id)
        evt_words = ["Logged #{evt.event_name}"]
        evt_words << "(#{evt.notes})" if evt_data[:notes].present?
        if evt_data[:timestamp].present?
          day = (
            if evt_data[:timestamp].today?
              "Today"
            elsif evt_data[:timestamp].tomorrow?
              "Tomorrow"
            elsif evt_data[:timestamp].yesterday?
              "Yesterday"
            else
              evt_data[:timestamp].to_formatted_s(:short)
            end
          )
          evt_words << "[#{day} #{evt.timestamp.to_formatted_s(:short_time)}]"
        end
        evt_words.join(" ")
      else
        evt.errors.full_messages.join("\n")
      end
    when :list
      List.find_and_modify(@user, @args)
    when :budget
      SmsMoney.parse(@user, @words)
    when :scheduled
      @args
    else
      combine = [@cmd, @args.presence].compact.join(" ")
      # if combine.match?(/\b(good morning|afternoon|evening)/)
      #   Find the weather, summarize events (ignore morning work meetings?)
      if combine.match?(/\b(hello|hey|hi|you there|you up)/)
        decorate(IM_HERE_RESPONSES.sample)
      elsif combine.match?(/\b(thank)/)
        decorate(APPRECIATE_RESPONSES.sample)
      else
        "I don't know how to #{rephrase_words(@words)}, sir."
      end
      # complete ["Check", "Will do, sir.", "As you wish.", "Yes, sir."]
    end
  end

  def decorate(words)
    words = words.gsub(/--time--/) { current_time_decoration }
  end

  def current_time_decoration
    case Time.current.hour
    when 0..4, 19..25 then :evening
    when 5..12 then :morning
    when 12..18 then :afternoon
    end
  end

  def rephrase_words(words)
    reversed_words = words.gsub(/\b(my)\b/i, "your")
    reversed_words = reversed_words.gsub(/\b(me|i)\b/i, "you")
    reversed_words = reversed_words.gsub(/[^a-z0-9]*$/, "").squish
    reversed_words = reversed_words.tap { |line| line[0] = line[0].downcase }
  end

  def parse_words
    token = SecureRandom.hex(3)
    simple_words = @words.downcase.squish
    # do you, would you, can I/you
    @asking_question = simple_words.match?(/\?$/) || simple_words.match?(/^(what|where|when|why|is|how|are)\s+(about|is|are|were|did|have|it)\b/)
    return parse_log_words if simple_words.match?(/^log\b/)

    # Logs have their own timestamp, so run them before checking for delayed commands
    return schedule_command if should_schedule?(simple_words)

    return parse_list_words if simple_words.match?(/^(add|remove)\b/)

    # Check lists since they have custom names
    if @user.lists.any?
      list_names = @user.lists.pluck(:name).map { |name| name.gsub(/[^a-z0-9 ]/i, "") }
      return parse_list_words if simple_words.match?(Regexp.new("\\b(#{list_names.join('|')})\\b", :i))
    end

    # Home should be !match? car\Tesla
    return parse_home_words if simple_words.match?(/\b(home|house|ac|up|upstairs|main|entry|entryway|rooms)\b/i)
    return parse_car_words if simple_words.include?("car")

    if simple_words.match?(Regexp.new("\\b(#{car_commands.join('|')})\\b"))
      return parse_car_words
    end

    return if parse_command(simple_words)

    return parse_text_words if simple_words.match?(/\b(text|txt|message|msg|sms)\b/i)
  end

  def extract_time(simple_words)
    simple_words = simple_words.gsub(/\b(later)\b/, "today")
    day_words = (Date::DAYNAMES + Date::ABBR_DAYNAMES + [:today, :tomorrow, :yesterday]).map { |w| w.to_s.downcase.to_sym }
    day_words_regex = Regexp.new("\\b(#{day_words.join('|')})\\b")
    time_words = [:second, :minute, :hour, :day, :week, :month]
    time_words_regex = Regexp.new("\\b(#{time_words.join('|')})s?\\b")
    time_str = simple_words[/\b(in) \d+ #{time_words_regex}/]
    time_str ||= simple_words[/(#{day_words_regex} )?\b(at) \d+:?\d*( ?(am|pm))?( #{day_words_regex})?/]
    time_str ||= simple_words[/\d+ #{time_words_regex} \b(from now|ago)\b/]
    time_str ||= simple_words[/((next|last) )?#{day_words_regex}/]

    [time_str, safe_date_parse(time_str.to_s.gsub(/ ?\b(at)\b ?/, " ").squish)]
  end

  def should_schedule?(simple_words)
    time_str, @scheduled_time = extract_time(simple_words)
    @remaining_words = @words.sub(Regexp.new(time_str, :i), "").squish if @scheduled_time

    @scheduled_time.present?
  end

  def schedule_command
    JarvisWorker.perform_at(@scheduled_time, @user.id, @remaining_words)
    @cmd = :scheduled
    @args = "I'll #{rephrase_words(@remaining_words)} later at #{@scheduled_time.to_formatted_s(:quick_week_time)}"
  end

  def parse_command(simple_words)
    return false unless @user.admin?
    tasks = ::CommandProposal::Task.where.not("REGEXP_REPLACE(COALESCE(friendly_id, ''), '[^a-z]', '', 'i') = ''")
    tasks = tasks.where(session_type: :function)

    return false unless tasks.any?

    command = tasks.find_by("? ILIKE CONCAT('%', friendly_id, '%""')", simple_words)
    command ||= tasks.find_by("? ILIKE CONCAT('%', REGEXP_REPLACE(friendly_id, '[^a-z]', '', 'i'), '%')", simple_words.gsub(/[^a-z]/i, ""))

    return false unless command.present?

    without_name = @words.gsub(Regexp.new("\\b(#{command.friendly_id.gsub("_", "\.\?")})\\b", :i), "")
    without_fn = without_name.squish.gsub(/^(fn|run|function)\b ?(fn|run|function)?/i, "")

    @cmd = :fn
    @args = {
      fn: command,
      args: without_fn.squish,
    }
    true
  end

  def parse_text_words
    @cmd = :text

    @args = @words.gsub(/#{rx_opt_words(:send, :shoot, :me, :a, :text, :txt, :sms)} ?\b(text|txt|message|msg|sms)s?\b ?#{rx_opt_words(:to, :that, :which, :me, :saying, :says)}/i, "")
    @args = @args.squish.capitalize
  end

  def rx_opt_words(*words)
    Regexp.new(words.map { |word| "(?: ?\\b#{word}\\b)\?" }.join(""), :i)
  end

  def safe_date_parse(timestamp)
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

    @args = {}
    time_str, extracted_time = extract_time(@words.downcase.squish)
    new_words = @words.sub(Regexp.new(time_str, :i), "") if extracted_time
    new_words = (new_words || @words).gsub(/^log ?/i, "")
    @args[:timestamp] = extracted_time
    @args[:event_name], @args[:notes] = new_words.gsub(/[.?!]$/i, "").squish.split(" ", 2)
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
    when :windows, :window, :vent
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
    when :honk, :horn
      "Honking the horn"
    when :defrost
      "Defrosting the car"
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
      :warm,
      :find,
      :where,
      :honk,
      :horn,
      :vent,
      :defrost,
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

    @args = @args.gsub(/\b(car)\b/, "").squish
    @args = @args.gsub(/where\'?s?( is)?/, "find")
    @args = @args.gsub(/\b(horn)\b/, "honk")
    @args = @args.gsub(/\b(vent)\b/, "windows")

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

  def home_response(settings)
    mode = nil
    temp = nil
    mode = :heat if settings.match?(/\b(heat)\b/i)
    mode = :cool if settings.match?(/\b(cool)\b/i)
    temp = settings[/\b\d+\b/].to_i if settings.match?(/\b\d+\b/)
    area = "upstairs" if settings.match?(/(up|rooms)/i)
    area ||= "main"

    if mode.present? && temp.present?
      "Set house #{area} #{mode == :cool ? "AC" : "heat"} to #{temp}°."
    elsif mode.present? && temp.blank?
      "Set house #{area} to #{mode}."
    elsif mode.blank? && temp.present?
      "Set house #{area} to #{temp}°."
    end
  end

  def parse_home_words
    @cmd = :home

    @args = @words
    if @args.match?(/(the|my) (\w+)$/i)
      end_word = @args[/\w+$/i]
      @args[/(the|my) (\w+)$/i] = ""
      @args = "#{end_word} #{@args}"
    end

    @args = @args.gsub(/\b(home|house)\b/i, "").squish
    @args = @args.gsub(/\b(ac)\b/i, "cool").squish

    @args.gsub!(/\b(the|set|to|is)\b/i, "")
    @args = @args.squish
  end
end
