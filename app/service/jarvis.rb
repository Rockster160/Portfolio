# [!] fixme now
# [>] hack, fix soon
# [^] Known Bug
# [ ] default importance
# [*] icebox, fix sometime™️
# [?] Needs checking - Might be fixed
# [/] Blocked Internally - Needs other features
# [X] Blocked Externally - Cannot be built

# =============================== Bugs ===============================

# ============================== TODO ================================
# [ ] Do stuff when I get home
# [ ] Do stuff when PT starts
# [ ] Do stuff 10 minutes before PT ends/starts
# [ ] Take me to Home Depot after PT - look for event called PT, schedule message to Jarvis at the ending time
# [ ] "at noon/midnight" should work
# [ ] Only send calendar start/directions to car if it’s off
# [ ] "Refresh" in Home (cell) should open the link for Nest
# [ ] Able to add other deliveries to Home(cell) with expected dates
# [ ] Fix Notes and other livekey cells to use new scrolling techniques used with Js.Js
# [ ] If a remind is within a few hours, say “I’ll remind you in 3 hours and 16 minutes to…”
# [ ] Jarvis conversations- can ask questions and allow responding back
# [*] Printer functions should not require dots to call
# [*] Car should show if camp/wait/etc mode is on
# [*] Passive notifications into Reminders cell- notification shows up, isn't noisy or obtrusive.
# [*] Log events with types - for example, WS should get logged and be visible on a page
# [*] Jarvis app - downloadable, tracks location, manages reminders, lists, automations, etc
# [*] Jarvis RNG
# [*] If car is off, location should be nearest store - if car is on, show street/city
# [*] Don’t show Log in Jarvis logs
# [*] Allow asking questions: What's my car temp? What's the house temp? etc...
#     * Pick random number, weather update...
# [*] Eventually? Able to say, "Remind me when I get home to..." - Could use some new JT trigger that pings phone location
#     * This triggers a job that reschedules itself for distance from house - 5 minutes
#     * When <5 minutes from house, trigger given action
# [*] Monitor phone location with FindMy API
# [*] Add budget stuff back in
# [*] > I don’t remember what I had for breakfast
# [*] > When was the last time I had <food>
# [*] > When was the last time I ate
# [*] > I don’t know the last time I ate
# [*] > What was the last thing I ate?
# [*] Somehow automate running specs to notify when there is a failing one Githook -> server -> test env on server?

# =============================== JarvisTasks ===============================
# [ ] Add some sort of interface for managing automations
#     * "X minutes before events called Y run Z"
#     * Parse this schedule on every calendar change, but only schedule for the next 6? hours?
# [*] Scrape a site. Provide a URL and some selectors and then set an interval and have it alert you when your requested check happens.
# [*] Sending good morning/day summary text
# [*] Check for hard freeze next day / next week

# =============================== Desired examples ===============================
# [/] get the car|house|home, how's the car, tell me about the car, give me the car
#     * Done after JV integrations are completed
# [/] Did I leave the car/house unlocked?
# [/] is the car unlocked?
# [/] is the AC on?
# [/] What did I have for breakfast?
#    > You had cereal this morning, sir.
# [*] Good morning / greeting
#    > Good morning, sir. The weather today is <>. You don't have anything scheduled after your morning meetings.
# [*] Good afternoon
#    > Good afternoon, sir. The weather for the rest of the day is <>. You don't have any more meetings scheduled.
# [*] Good night
#    > Good night, sir. The weather tomorrow is <>. You don't have anything scheduled after your morning meetings.
#    > You'll need to leave for PT by 9:55

class Jarvis
  MY_NUMBER = "3852599640".freeze

  def self.log(*messages)
    PrettyLogger.log(*messages)
  end

  def self.command(user, words)
    return if words.blank?

    res, res_data = new(user, words).command

    if user.persisted? && res.present?
      JarvisChannel.broadcast_to(
        user,
        { say: res, data: res_data },
      )
    end
    return res if res_data.blank?

    [res, res_data]
  end

  def self.broadcast(user, msg, channel=:ws)
    return unless user.persisted?
    return if msg.blank?

    case channel
    when :ping then ::WebPushNotifications.send_to(user, { title: msg })
    when :sms then SmsWorker.perform_async(user.phone, msg)
    when :ws then JarvisChannel.broadcast_to(user, { say: msg })
    else
      msg
    end
  end

  # "Me" commands
  def self.cmd(msg)
    command(User.me, msg)
  end

  def self.say(msg, channel=:ws)
    broadcast(User.me, msg, channel)
  end

  def self.ping(msg, channel=:ping)
    say(msg, channel)
  end

  def self.sms(msg, channel=:sms)
    say(msg, channel)
  end

  def self.send(data, channel=:ws)
    return if data.blank?
    return say(data, channel) if channel != :ws

    ActionCable.server.broadcast(:jarvis_channel, { data: data })
  end

  def self.reserved_words
    @@reserved_words ||= actions.flat_map(&:reserved_words)
  end

  delegate :actions, to: :class
  def self.actions
    # Order sensitive classes to iterate through and attempt commands
    # @asking_question = simple_words.match?(/\?$/) || simple_words.match?(/^(what|where|when|why|is|how|are)\s+(about|is|are|were|did|have|it)\b/)
    [
      Jarvis::Say,            # √ -- Eventually remove this as well. This is just a websocket.
      Jarvis::Log,            # √ -- Could probably migrate to Jil?
      Jarvis::ScheduleParser, # √ KEEP! This will be the magic that delays things via words. Should be disable-able?
      Jarvis::Navigate,       # -- Move to Jil after Tesla
      Jarvis::Wifi,           # -- Move to Jil after QR
      Jarvis::List,           # ? Maybe integration? Maybe default?
      Jarvis::Printer,        # -- Move to Jil whenever
      Jarvis::Nest,           # -- Move to Jil after Oauth
      Jarvis::Tesla,          # -- Move to Jil after Oauth
      Jarvis::Sms,            # Contains logic for remind and ping - need to extract those. Then not sure what to do about SMS in general...
      Jarvis::Venmo,          # -- Move to Jil after Oauth
      Jarvis::Talk,           # √ Controls fallback Jarvis responses
    ]
  end

  def initialize(user, words)
    @user = user
    @words = NumberParser.parse(words.to_s)

    Time.zone = "Mountain Time (US & Canada)"
  end

  def command
    time_str, scheduled_time = ::Jarvis::Times.extract_time(@words.downcase.squish)
    remaining_words = @words
    remaining_words = @words.sub(Regexp.new("(?:\b(?:at|on)\b )?#{time_str}", :i), "").squish if scheduled_time
    timestamp = (scheduled_time || Time.current).in_time_zone(@user.timezone).iso8601
    tasks = ::Jil.trigger_now(
      @user, :tell,
      { words: remaining_words, timestamp: timestamp, full: @words }
    )
    return tasks.last.last_message if tasks.any?(&:stop_propagation?)

    tasks.select { |t| t.trigger_type == :tell }.last&.tap { |task|
      return task.last_message
    }

    current_reserved_words = Jarvis.reserved_words.dup
    actions.lazy.map { |action_klass| # lazy map means stop at the first one that returns a truthy value
      action_klass.attempt(@user, @words, current_reserved_words)
    }.compact_blank.first || tasks.last&.last_message
  rescue Jarvis::Error => e
    e.message
  end
end
