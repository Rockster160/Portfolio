# ============================ High TODO =============================
# Able to input next week lane to Jarvis somehow
# ** Every bowling night should remind Lane, brace, belt as well as usual conditioning and GPS
# Add some sort of interface for managing automations
# ** "X minutes before events called Y run Z command"
# ** Parse this schedule on every calendar change, but only schedule for the next 6? hours?
# Jarvis should interpret word numbers "two"
# Car should show if camp/wait/etc mode is on
# ActionEvent Index should show total/page counts (especially when filtering)
# Passive notifications into Reminders cell- notification shows up, isn't noisy or obtrusive.
# Log events with types - for example, WS should get logged and be visible on a page
# Remind should always be future
# "take" should not have such high priority
# # "at noon/midnight" should work
# Printer functions should not require dots to call
# Only send start/directions to car if it’s off
# "Refresh" in Home (cell) should open the link for Nest
# Able to add other deliveries to Home(cell) with expected dates
# Jarvis app - downloadable, tracks location, manages reminders, lists, automations, etc
# Jarvis RNG
# Fix Notes and other livekey cells to use new scrolling techniques used with Js.Js
# Scrape a site. Provide a URL and some selectors and then set an interval and have it alert you when your requested check happens.
# Some reminders in [Reminders] should only show up when it's time, not 6-7 hours before...
# Jarvis specific dates don't get picked up "Remind me Oct 23 at 9:32am to wish B Happy Birthday"
# If car is off, location should be nearest store - if car is on, show street/city
# Don’t show Log in Jarvis logs
# Navigate should also start the car (if not already on)


# =============================== Bugs ===============================
# Always navving home with directions
# "Take" is acting as a keyword for traveling, but should not take priority over "remind"
# -- Should only be "take ME"
#   [5:01 PM] Navigating to remind steak out
#   [1:14 PM] I'll remind you to take steak out on Mon Aug 8 at 5:00 PM


# =============================== TODO ===============================
# Allow asking questions: What's my car temp? What's the house temp? etc...
# * Pick random number, weather update...
# create a timer that sends a WS to Dashboard and starts a timer (or sms? How to determine which is which?)
# Ability to undo messages or logs
# If question that doesn't match others, google and read the first result?
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
# Remind me every 5 minutes to jump until I say stop 😱
# Jarvis, Venmo X $Y
# Somehow automate running th`e soecs to notify when there is a failing one Githook -> server -> test env on server?
# Jarvis conversations- can ask questions and allow responding back
# Auto message when garage is still open after a certain time
# Add contacts to Jarvis for navigating

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
      Jarvis::ScheduleParser,
      Jarvis::Navigate,
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
