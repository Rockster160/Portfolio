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
# Text me at 11:15 AM tomorrow saying Move schedule for Friday


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
      Jarvis::Log,
      Jarvis::Schedule,
      Jarvis::List,
      Jarvis::Nest,
      Jarvis::Tesla,
      Jarvis::Cmd,
      Jarvis::Sms,
    ]
  end

  def command
    actions.lazy.map do |action_klass| # lazy map means stop at the first one that returns a truthy value
      action_klass.attempt(@user, @words)
    end.compact_blank.first
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
    when :budget
      SmsMoney.parse(@user, @words)
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
    # return parse_log_words if simple_words.match?(/^log\b/)

    # Logs have their own timestamp, so run them before checking for delayed commands
    # return schedule_command if should_schedule?(simple_words)

    # return parse_list_words if simple_words.match?(/^(add|remove)\b/)
    #
    # # Check lists since they have custom names
    # if @user.lists.any?
    #   list_names = @user.lists.pluck(:name).map { |name| name.gsub(/[^a-z0-9 ]/i, "") }
    #   return parse_list_words if simple_words.match?(Regexp.new("\\b(#{list_names.join('|')})\\b", :i))
    # end

    # Home should be !match? car\Tesla
    # return parse_home_words if simple_words.match?(/\b(home|house|ac|up|upstairs|main|entry|entryway|rooms)\b/i)
    # return parse_car_words if simple_words.include?("car")
    #
    # if simple_words.match?(Regexp.new("\\b(#{car_commands.join('|')})\\b"))
    #   return parse_car_words
    # end

    # return if parse_command(simple_words)

    # return parse_text_words if simple_words.match?(/\b(text|txt|message|msg|sms)\b/i)
  end

  def parse_list_words
    @cmd = :list
    # Could probably move all of the word parsing logic into here rather than the model
    @args = @words
  end
end
