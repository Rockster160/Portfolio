Buddy::Tools.register(
  name:        :alarm,
  description: <<~TXT,
    Set an ALARM: it rings out loud and keeps ringing until they acknowledge it,
    and pushes to their phone the same moment. "Wake me at 6:30", "alarm in 20
    minutes", "set an alarm for the next time the washer finishes".

    The distinction that matters is being LOOKED AT versus being HEARD.
    `remind_when` and `schedule_reminder` put a line in the thread and send one
    push - fine for something they'll deal with when they next pick up their
    phone. This makes a noise in the room that doesn't stop on its own. Reach
    for it whenever they say ALARM, or say something that only works if it
    interrupts them: waking up, the oven, the laundry, a meeting they cannot be
    late for.

    **One or the other, never both.** An alarm alongside a reminder for the
    same moment is two things going off, and the reply then describes the
    quiet one: "wake me at 6:30 tomorrow" came back as an alarm AND a reminder,
    announced as "you've got a wake-up reminder" - so the thing that would
    actually wake them went unmentioned and the thread carried a duplicate.

    Say when in exactly ONE of three ways:
      `at`      - a clock time, as an ISO datetime. "6:30 tomorrow", "at 7pm".
      `seconds` - a stretch of time from now. "in 20 minutes" is 1200.
      `trigger` - a real-world condition, described below.

    An alarm reaches 24 hours out and no further. Anything beyond that is
    `schedule_reminder`, and so is anything that repeats on a calendar
    ("every weekday at 7") - `repeat` here is about a condition happening
    again, not about a daily alarm.

    `set_timer` is still the right tool when they said TIMER. A timer is a
    countdown they're watching (pasta, a rotation); an alarm is a moment they
    want to be interrupted at. Both ring - follow the word they used.

    `label` is what the alarm is for, in their words - "Wake up", "Washer's
    done", "Leave for the airport". It is what they'll see on the lock screen
    and what's read out when it goes off, so write the finished thing rather
    than a description of the request ("remind me about the washer" is not it).
    Open it with a glyph only if it adds something; one is added for you.

    ## Hanging one off a condition

    `trigger` picks the condition, exactly as it does for `remind_when`:
      "arrive" / "depart" - a place. `target` = the place name.
      "chore"  - a chore being marked done. `target` = the chore name.
      "event"  - an activity being logged. `target` = the event name.
      "agenda" - something added to a calendar. `target` = the calendar name.
      "whisper" - the dog's day changing. `target` is `up`, `nap`, `bedtime`,
                 `home` or `out`. "Wake me when the puppy gets up" is this.
      "deploy" - a Portfolio deploy finishing. No `target`.
      "custom" - anything else, and that's most of what an alarm is for. Every
                 physical thing in the house - the washer, the dryer, the
                 doorbell, the doors, the printer, the buttons, the sensors -
                 reports in as an ordinary trigger, so it is this. Pass
                 `listener` instead of `target`.

    **`custom` means calling `read_listener_guide` first, every time, and it is
    not optional here.** It returns the real listeners off their own automations,
    and copying a key path out of one is the difference between an alarm that
    goes off and one that never does. Both failures look the same from outside:
    silence. A listener that PARSES is not a listener that FIRES - `laundry` is
    a real scope with a real `action` key, and `laundry:action:stop` was still
    an alarm that could never ring, because nothing ever fires that scope with
    that value. Read what the payloads actually carry; don't reason about what
    they ought to.

    `when_phrase` (custom only) says what that listener MEANS in their words -
    "when the washer stops". It's what they'll read in their reminders list.

    `repeat` true makes it a standing alarm ("every time the washer finishes")
    instead of a one-off for the next occurrence. Pair a repeating alarm with
    `expires` whenever they bounded it in time ("today", "while I'm away") -
    an alarm nobody can turn off is worse than one that never rings. Neither
    applies to a clock or duration alarm, which goes off once.
  TXT
  args: {
    label:       { type: :string,  required: true,  description: "What the alarm is for, as they'll read it when it goes off (\"Wake up\")" },
    at:          { type: :string,  required: false, description: "Clock time to go off, as an ISO datetime. Within 24 hours." },
    seconds:     { type: :integer, required: false, description: "Go off this many seconds from now (\"in 20 minutes\" = 1200)" },
    trigger:     { type: :enum,    required: false, values: Buddy::WatchCondition::TRIGGERS, description: "Condition type, when the alarm hangs off something happening rather than a time" },
    target:      { type: :string,  required: false, description: "Place / chore / event / calendar name the condition is about (omit for deploy and custom)" },
    listener:    { type: :string,  required: false, description: "Jil listener string. Required for trigger=custom. Read read_listener_guide first, every time." },
    when_phrase: { type: :string,  required: false, description: "Plain-language meaning of the listener (\"when the washer stops\"). Required for trigger=custom." },
    repeat:      { type: :boolean, required: false, default: false, description: "Ring every time (true) instead of just the next time (false)" },
    expires:     { type: :string,  required: false, description: "Last day it stays armed: \"today\", \"tomorrow\", \"N days/weeks\", or YYYY-MM-DD" },
  },
  # Same gating as remind_when: an alarm on a chore completion would announce
  # the household's chores to someone the chore feature is switched off for.
  gated_values: { trigger: Buddy::WatchCondition::GATED },
  confirm: ->(payload, ctx) {
    raise "an alarm needs to say what it's for" if payload[:label].to_s.strip.blank?

    # A clock time and a duration both mean "no condition, just a countdown",
    # but they stay APART all the way through. A duration turned into an
    # absolute moment and back loses the anchoring Buddy::Timers does - "20
    # minutes" measured from when the turn ended instead of when they asked is
    # 19:59, every time. Only a CONDITION needs a watch.
    at      = payload[:at].to_s.strip
    seconds = payload[:seconds].to_i

    if at.present? || seconds.positive?
      raise "an alarm goes off at a time OR when something happens, not both" if payload[:trigger].present?

      fire_at = (at.present? ? (ctx.resolve_time(at) || raise("couldn't read #{at.inspect} as a time")) : seconds.seconds.from_now)
      if (reason = Buddy::Alarms.out_of_reach(fire_at))
        raise reason
      end

      when_str = ctx.friendly_future(fire_at)
      next {
        summary:  "Sound an alarm #{when_str}?",
        resolved: {
          fire_at_iso: (fire_at.iso8601 if at.present?),
          seconds:     (seconds if at.blank?),
          human_when:  when_str,
        }.compact,
      }
    end

    raise "an alarm needs a time (`at` or `seconds`) or a condition (`trigger`)" if payload[:trigger].blank?

    condition = Buddy::WatchCondition.resolve(payload, ctx)
    every     = ActiveModel::Type::Boolean.new.cast(payload[:repeat])
    human = every ? Buddy::WatchCondition.repeating_phrase(condition.human) : condition.human

    # A bound on how long it stays armed, not a schedule - the condition still
    # decides when it rings.
    expires_at = ctx.end_of_day_for(payload[:expires])
    raise "couldn't read #{payload[:expires].inspect} as a day" if payload[:expires].present? && expires_at.nil?

    framed = "Sound an alarm #{human}"
    framed = "#{framed}, until #{expires_at.strftime("%b %-e")}" if expires_at

    # Two alarms on one condition is one alarm they can't switch off, since
    # acknowledging is a single tap and the second one starts again underneath
    # it. Worth saying out loud before a duplicate is added silently.
    twin    = ctx.existing_watch_twin(condition.scope, condition.match, owner: condition.owner, listener: condition.listener)
    warning = twin && "One is ALREADY listening for this: #{twin.body.to_s.truncate(60).inspect}. " \
                      "Setting this leaves both. Say that plainly and offer to retire the old one " \
                      "(cancel_reminder) - don't add a second one silently."

    {
      summary:  ["#{framed}?", warning].compact.join(" "),
      resolved: {
        trigger_scope:  condition.scope,
        match:          condition.match,
        listener:       condition.listener,
        human_when:     human,
        one_shot:       !every,
        place_known:    condition.place_known != false,
        place_name:     condition.place_name,
        watch_owner_id: condition.owner.id,
        expires_at_iso: expires_at&.iso8601,
      },
    }
  },
  label: ->(payload, _ctx) {
    "Alarm #{payload[:human_when]}: #{payload[:label].to_s.truncate(40)}"
  },
  execute: ->(payload, ctx) {
    # A clock/duration alarm is a countdown and nothing else - there's no
    # condition to watch for, so no watch is written.
    if payload[:fire_at_iso].present? || payload[:seconds].to_i.positive?
      shared = { user: ctx.user, label: payload[:label].to_s.strip, conversation: ctx.conversation }
      timer  = (
        if payload[:fire_at_iso].present?
          Buddy::Alarms.at!(fire_at: Time.zone.parse(payload[:fire_at_iso].to_s), **shared)
        else
          Buddy::Alarms.in!(seconds: payload[:seconds].to_i, **shared)
        end
      )
      return { timer_id: timer.id, human_when: payload[:human_when] }
    end

    # A place we couldn't resolve would store a name-only match that never
    # fires. Report it so Buddy asks where the place is instead of pretending.
    return { unknown_place: true, place_name: payload[:place_name] } if payload[:place_known] == false

    owner_id = payload[:watch_owner_id].presence || ctx.user.id
    owner    = owner_id.to_i == ctx.user.id ? ctx.user : User.find(owner_id)

    watch = BuddyWatch.create!(
      user:              owner,
      byte_conversation: Buddy::CompanionRelay.conversation_for(owner),
      kind:              :alarm,
      body:              payload[:label].to_s.strip.first(500),
      trigger_scope:     payload[:trigger_scope].to_s,
      listener:          payload[:listener].presence,
      match:             payload[:match] || {},
      one_shot:          ActiveModel::Type::Boolean.new.cast(payload[:one_shot]),
      expires_at:        (Time.zone.parse(payload[:expires_at_iso].to_s) if payload[:expires_at_iso].present?),
      metadata:          { "human_when" => payload[:human_when].to_s },
    )
    {
      watch_id:   watch.id,
      human_when: payload[:human_when],
      listener:   watch.listener,
      expires_at: watch.expires_at&.iso8601,
    }
  },
  # Setting one is safe and reversible (cancel_reminder undoes it), so it runs
  # without a checkbox and drops an activity receipt - same as remind_when.
  auto:    true,
  receipt: ->(result, ctx) {
    if result[:unknown_place]
      where = result[:place_name].to_s.strip
      "Not sure where #{where.presence || "that"} is - what's the address, or is it on your calendar?"
    elsif result[:timer_id]
      "#{ctx.buddy_name} will sound an alarm #{result[:human_when]} ⏰"
    else
      line = "#{ctx.buddy_name} will sound an alarm #{result[:human_when]} ⏰"
      ends = (Time.zone.parse(result[:expires_at].to_s) rescue nil)
      line = "#{line}, until #{ctx.friendly_day(ends)}" if ends
      # A hand-written listener shows what it's really matching underneath.
      # This is the one moment they can catch one that's subtly wrong, before it
      # sits there for a month not ringing.
      result[:listener].present? ? "#{line}\n`#{result[:listener]}`" : line
    end
  },
)
