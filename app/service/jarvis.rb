# =============================== TODO ===============================
# Jarvis schedule responding with array
# Remind me should be alias for text me
# Text me without message will send a greeting - Orrrrrr. "You asked me to text you, sir."
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
  MY_NUMBER = "3852599640"

  def self.command(user, words)
    res, res_data = new(user, words).command

    ActionCable.server.broadcast("jarvis_channel", say: res, data: res_data) if res.present?
    [res, res_data]
  end

  def self.say(msg, channel=:ws)
    return unless msg.present?

    case channel
    when :sms then SmsWorker.perform_async(MY_NUMBER, msg)
    when :ws then ActionCable.server.broadcast("jarvis_channel", say: msg)
    else
      msg
    end
  end

  def self.send(data, channel=:ws)
    return unless data.present?

    case channel
    when :sms then SmsWorker.perform_async(MY_NUMBER, data)
    when :ws then ActionCable.server.broadcast("jarvis_channel", data: data)
    else
      data
    end
  end

  def initialize(user, words)
    @user = user
    @words = words.to_s
    Time.zone = "Mountain Time (US & Canada)"
  end

  def actions
    # Order sensitive classes to iterate through and attempt commands
    [
      # Jarvis::Log,
      # Jarvis::Schedule,
      # Jarvis::List,
      Jarvis::Nest,
      Jarvis::Car,
      # Jarvis::Cmd,
      # Jarvis::Sms,
    ]
  end

  def command
    actions.lazy.map do |action_klass| # lazy map means stop at the first one that returns a truthy value
      action_klass.attempt(@user, @words)
    end.first
  rescue Jarvis::Error => msg
    Jarvis.say(msg)
  end

  def old_command
    return "Sorry, I don't know who you are." unless @user.present?

    parse_words
    unless @cmd.present?
      @cmd, @args = @words.squish.downcase.split(" ", 2)
    end

    case @cmd.to_s.to_sym
    when :text
      return "Sorry, you can't do that." unless @user.admin?

      SmsWorker.perform_async(MY_NUMBER, @args)

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
        Jarvis::Text.im_here
      elsif combine.match?(/\b(thank)/)
        Jarvis::Text.appreciate
      else
        "I don't know how to #{Jarvis::Text.rephrase(@words)}, sir."
      end
      # complete ["Check", "Will do, sir.", "As you wish.", "Yes, sir."]
    end
  end

  def parse_words
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
    # return parse_home_words if simple_words.match?(/\b(home|house|ac|up|upstairs|main|entry|entryway|rooms)\b/i)
    # return parse_car_words if simple_words.include?("car")
    #
    # if simple_words.match?(Regexp.new("\\b(#{car_commands.join('|')})\\b"))
    #   return parse_car_words
    # end

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
    @args = "I'll #{Jarvis::Text.rephrase(@remaining_words)} later at #{@scheduled_time.to_formatted_s(:quick_week_time)}"
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
end
