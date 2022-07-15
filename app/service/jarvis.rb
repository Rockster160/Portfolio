# =============================== TODO ===============================
# Allow asking questions: What's my car temp? What's the house temp? etc...
# * Pick random number, weather update...
# create a timer that sends a WS to Dashboard and starts a timer (or sms? How to determine which is which?)
# Ability to undo messages or logs
# If question that doesn't match others, google and read the first result?
# (do thing) tonight > schedule thing for 7pm
# (do thing) in the morning > schedule thing for 8am
# Able to schedule an event for "every day" -> For example, sending good morning text
# Eventually? Able to say, "Remind me when I get home to..."
# * This triggers a job that reschedules itself for distance from house - 5 minutes
# * When <5 minutes from house, trigger given action
# Eventually? "Let me know before any night that's going to be a hard freeze"
# Monitor phone location with FindMy API
# Add budget stuff back in
# > I don’t remember what I had for breakfast
# > When was the last time I had <food>
# > When was the last time I ate
# > I don’t know the last time I ate
# > What was the last thing I ate?
# Able to see schedules somehow
# Able to paste in an address and have it go to the car
# Remind me every 5 minutes to jump until I say stop 😱


# =============================== Desired examples ===============================
# get the car|house|home, how's the car, tell me about the car, give me the car
# Did I leave the car/house unlocked?
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
# Start my car before I need to leave for PT


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
    return res if res_data.blank?
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

  def self.reserved_words
    @@reserved_words ||= actions.flat_map { |action| action.reserved_words }
  end

  delegate :actions, to: :class
  def self.actions
    # Order sensitive classes to iterate through and attempt commands
    # @asking_question = simple_words.match?(/\?$/) || simple_words.match?(/^(what|where|when|why|is|how|are)\s+(about|is|are|were|did|have|it)\b/)
    [
      Jarvis::Log,
      Jarvis::Schedule,
      Jarvis::List,
      Jarvis::Printer,
      Jarvis::Nest,
      Jarvis::Tesla,
      Jarvis::Garage,
      Jarvis::Cmd,
      Jarvis::Sms,
      Jarvis::Talk,
    ]
  end

  def initialize(user, words)
    @user = user
    @words = words.to_s
    Time.zone = "Mountain Time (US & Canada)"
  end

  def command
    actions.lazy.map do |action_klass| # lazy map means stop at the first one that returns a truthy value
      action_klass.attempt(@user, @words)
    end.compact_blank.first
  rescue Jarvis::Error => err
    err.message
  end
end
