Buddy::Tools.register(
  name:        :remind_when,
  description: <<~TXT,
    Set a reminder that fires when a real-world CONDITION happens, not at a
    clock time. Use for "remind me to X when / the next time I <arrive /
    leave / do> Y". For plain time-based reminders use schedule_reminder.

    This is a nudge that fires once and evaporates. "Add an agenda task to
    shower once I get home" is asking for a row on the AGENDA, so it's
    `add_agenda_item` - the condition just tells you when to put it. Reach
    for this tool only when the nudge itself is the thing they wanted, or
    alongside an agenda item when they want both.

    `trigger` picks the condition:
      "arrive" - when they get to a place. `target` = the place name
                 ("Costco", "the gym", "home").
                 e.g. "remind me to grab my prescription next time I'm at Costco".
      "depart" - when they leave a place. `target` = the place name.
      "chore"  - when a chore is marked done. `target` = the chore name
                 ("Brush Teeth"). e.g. "next time I brush my teeth, remind
                 me to floss".
      "event"  - when they log an activity/event. `target` = the event name
                 ("Coffee", "Workout").
      "agenda" - when something is added to one of their calendars. `target` =
                 the calendar name ("Ours", "our agenda", "Work").
                 e.g. "whenever something's added to our agenda, let me know".
      "deploy" - when a Portfolio deploy finishes, whether it succeeded or
                 failed. No `target`. Pair with `repeat: true` for a standing
                 "ping me on every deploy"; you'll be told which outcome it
                 was when it fires.
      "custom" - anything else that happens: a list getting an item, a prompt
                 arriving, the car parking - and everything PHYSICAL, which is
                 most of what people actually want watched. The doorbell, the
                 cameras, the door and kennel sensors, the buttons around the
                 house and the printer all report in as ordinary triggers, so
                 "tell me when someone's at the front door" is this. Pass
                 `listener` instead of `target`. USE ONE OF THE NAMED TRIGGERS
                 ABOVE WHEN ONE FITS - they're resolved against real chores,
                 places and calendars, and a hand-written listener is not. This
                 is for what they don't cover.

    `listener` (custom only) is a Jil listener string, e.g.
    `item:action:added item:list:name:/^Groceries$/`. **Call
    `read_listener_guide` before writing one, every time** - it returns the
    syntax plus the listeners already running on their own automations, and
    copying a real key path from those is the difference between a watch that
    fires and one that silently never does. Do not guess at payload keys.

    That tool is also how you find out whether something is watchable in the
    first place, by passing what they called it (`about: "doorbell"`). The house
    sensors and cameras appear NOWHERE else you can see - not in `jil_triggers`,
    not in any context section - so your not knowing about a thing is not
    evidence it isn't there. **Search before you tell anyone you can't watch
    something.** Answering "I don't have a doorbell watch to hook into" while
    three doorbell automations were running is the failure this exists to
    prevent, and repeating it after they say it's set up is worse.

    `when_phrase` (custom only) says what that listener MEANS, in their words:
    "when something is added to the Claude list", "when the car parks at home".
    It's what they'll read in their reminders list; the listener itself shows
    underneath as the detail. Write it the way they said it, starting with
    "when", and don't describe the syntax - "when item:action:added fires" tells
    them nothing they wanted to know.

    `text` is what to remind them of. It fires ONCE by default (the next time
    the condition happens). Set `repeat` true only if they clearly want it
    every time ("every time I get home...").

    **A repeating watch bounded in time needs `expires`, and they say so more
    often than they realise.** "Let me know each time the doorbell sees
    somebody TODAY" is `repeat: true` with `expires: "today"` - without the
    second half it keeps pinging them next week about a day that's over, and
    the only way it stops is somebody noticing and deleting it. Any "today",
    "this week", "while I'm away", "until Friday" is this. A watch with no
    end is for the standing ones: deploys, the Claude list, the front door
    generally.

    **How you write `text` depends on `repeat`, and it matters.** A one-shot
    fires once and you compose the message then, so `text` can be about the
    intent. A REPEATING one is delivered exactly as written, every single time,
    without you in the loop - it's a feed, and a feed doesn't need you to say
    it in a fresh way sixty times a day. So write those as the finished
    sentence they'll read: "🔔 Claude list got a new item in Ocs-Backend", not
    "ping me when the Claude list gets an item". Whatever the trigger carries -
    the item, the title - is appended for you, so don't try to write it in.
    **Open it with a glyph**, since nothing adds one for you and these land on
    a lock screen where the first character is what's read first.

    `text` is a LIQUID TEMPLATE, which matters as soon as they want anything
    other than a fixed sentence with the detail on the end:
    - `{{ name }}` is what changed, and any other key reads straight off the
      trigger - `{{ list }}`, `{{ section }}`. Writing one of these puts the
      detail where they want it instead of at the end, and nothing is appended.
    - Filters clean it up: `{{ name | remove: ">" | strip }}` for a list whose
      items arrive prefixed, `{{ name | truncate: 40 }}` for a long one.
    - `{% if %}` picks between two messages:
      `{% if outcome == "failed" %}❌ it broke{% else %}🚀 all good{% endif %}`.
    - `{{ now }}`, `{{ today }}`, `{{ weekday }}`, `{{ user }}`, `{{ buddy }}`
      and `{{ greeting }}` are there whatever the trigger was.

    A plain sentence is still the right answer most of the time. Reach for a
    template when they've said something a sentence can't do - where the detail
    goes, what to strip off it, or which of two things to say.

    `notify` (optional) sends it to a household member instead of the user:
    "whenever I add to our agenda, let Rocco know" → notify="Rocco". It reaches
    them as a message FROM this person, delivered the same way `message_partner`
    delivers one now - so this is also how "message Chelsea when someone's at
    the door" or "tell her the next time a deploy finishes" gets done, and
    `text` should be written as the note they'll actually read. Omit for an
    ordinary reminder-to-self. Must be someone in the household.

    ## Doing something instead of saying something

    `run` turns this from a nudge into an automation: name a Jil task from
    `jil_triggers` and it FIRES when the condition hits, with nothing said to
    anyone. "Trigger whisper-quiet the next time the doggy door opens" is
    `trigger: "custom"` with the sensor's listener and `run: "Whisper Quiet"`.

    `delay` (seconds, up to 900) waits that long after the condition before
    running it - "ten seconds after the doggy door" is `delay: 10`. It only
    applies with `run`.

    This is a real capability, so don't decline it. "I can watch the sensor but
    I can't make it wait ten seconds after" was wrong: one call sets the watch,
    the wait and the trigger. Use `run` only when they want a THING to happen;
    if they want to be told, that's `text` as usual. `notify` and `run` don't
    combine - one is a message to a person, the other isn't a message at all.

    `timer` starts a COUNTDOWN each time the condition hits - "set a 1 second
    timer every time something comes into the Claude list" is `timer: 1` on a
    custom listener. **When they say timer, they mean a timer.** A reminder is
    a message they have to be looking at; a timer alarms out loud, which is the
    whole reason to ask for a one-second one. `set_timer` only counts down from
    now, and that is not a reason to talk them into a reminder instead - this
    arg is how a timer hangs off a condition. Like `run`, it says nothing and
    doesn't combine with `notify`.

    IMPORTANT for places (arrive/depart): the system resolves the place from
    the person's contacts and calendar. You do NOT know in advance whether it
    can - so don't state the reminder is set in your own words, and don't
    claim to know where a place is. Let the receipt confirm. If the place
    can't be resolved, the receipt says so and you should then ask where it
    is (an address, or "it's on my calendar"). Don't explain HOW arrival is
    detected - just that you'll let them know.
  TXT
  args: {
    text:        { type: :string,  required: true,  description: "What to remind them of" },
    trigger:     { type: :enum,    required: true,  values: Buddy::WatchCondition::TRIGGERS, description: "Condition type" },
    target:      { type: :string,  required: false, description: "Place / chore / event / calendar name the condition is about (omit for deploy and custom)" },
    listener:    { type: :string,  required: false, description: "Jil listener string. Required for trigger=custom, ignored otherwise. Read read_listener_guide first." },
    when_phrase: { type: :string,  required: false, description: "Plain-language meaning of the listener (\"when something is added to the Claude list\"). Required for trigger=custom." },
    repeat:      { type: :boolean, required: false, default: false, description: "Fire every time (true) instead of just the next time (false)" },
    notify:      { type: :string,  required: false, description: "Household member to notify instead of the user (optional)" },
    run:         { type: :string,  required: false, description: "Jil task name to FIRE when the condition hits, instead of saying anything. Verbatim from jil_triggers." },
    delay:       { type: :integer, required: false, description: "Seconds to wait after the condition before running it (max 900). With `run` only." },
    timer:       { type: :integer, required: false, description: "Start a countdown of this many seconds each time the condition hits, instead of saying anything. Only for a real WAIT after the condition (\"start a 10 minute timer when I get home\") - to ring the moment it happens, use the `alarm` tool instead of a 1-second countdown." },
    expires:     { type: :string,  required: false, description: "Last day it stays armed: \"today\", \"tomorrow\", \"N days/weeks\", or YYYY-MM-DD. Use whenever they bound it in time." },
  },
  # Watching for an arrival or a deploy is everyone's. The other three reach
  # into a feature: a chore watch would tell someone without chores when the
  # rest of the household finished theirs, which is exactly the visibility the
  # block exists to prevent.
  gated_values: { trigger: Buddy::WatchCondition::GATED },
  confirm: ->(payload, ctx) {
    # The condition - place, chore, calendar, listener - is shared with `alarm`
    # and lives in Buddy::WatchCondition. What's left here is what a REMINDER
    # does with it.
    condition   = Buddy::WatchCondition.resolve(payload, ctx)
    scope       = condition.scope
    match       = condition.match
    human       = condition.human
    owner       = condition.owner
    place_known = condition.place_known
    place_name  = condition.place_name

    # An action watch resolves its task NOW, not at fire time. The whole point
    # of this shape is that nothing has to think when the sensor trips, so a
    # name that doesn't match anything has to fail here, while there's still
    # someone in the conversation to tell.
    run_name = payload[:run].to_s.strip
    run_task = nil
    if run_name.present?
      raise "running an automation needs Jil access" unless Buddy::Features.enabled?(ctx.user, :jil)
      raise "a watch either tells someone or runs something, not both" if payload[:notify].to_s.strip.present?

      run_task = ctx.resolve_jil_trigger(run_name)
      raise "no Jil task matches #{run_name.inspect}" if run_task.nil?
      # Nothing fills in a payload when a sensor trips, so a listener with data
      # filters on it would be wired up and then never fire.
      unless run_task[:plain]
        raise "#{run_task[:name]} needs data to fire (`#{run_task[:listener]}`), so it can't hang off a watch"
      end
    end
    delay = payload[:delay].to_i.clamp(0, BuddyWatch::MAX_ACTION_DELAY)
    delay = 0 if run_task.nil?

    # A countdown rather than a message. Clamped by the same rule an ordinary
    # timer is, so a watch can't create one the timer stack would refuse.
    timer_seconds = payload[:timer].to_i
    if timer_seconds.positive?
      raise "a watch either tells someone or sets a timer, not both" if payload[:notify].to_s.strip.present?
      raise "a watch either runs a task or sets a timer, not both" if run_task

      timer_seconds = timer_seconds.clamp(1, Buddy::Timers::MAX_SECONDS)
    end

    every = ActiveModel::Type::Boolean.new.cast(payload[:repeat])
    human = Buddy::WatchCondition.repeating_phrase(human) if every

    # Who gets the heads-up. An explicit `notify` wins; otherwise, if the watch
    # has to be owned by someone else (an agenda the user doesn't own), the
    # requester still gets told. The watch fires for `owner`, so a recipient who
    # IS the owner is just an ordinary self-watch (notify_user nil).
    notify_name = payload[:notify].to_s.strip
    explicit    = notify_name.present? ? ctx.resolve_household_user(notify_name) : nil
    raise "I'm not sure who #{notify_name} is" if notify_name.present? && explicit.nil?

    desired     = explicit || (owner.id == ctx.user.id ? nil : ctx.user)
    notify_user = desired && desired.id != owner.id ? desired : nil
    recipient   = notify_user || owner
    to_self     = recipient.id == ctx.user.id

    # A bound on how long it stays armed, not a schedule - the condition still
    # decides when it fires. Raised rather than ignored: a watch they asked to
    # stop after today and which doesn't is exactly the one nobody cleans up.
    expires_at = ctx.end_of_day_for(payload[:expires])
    raise "couldn't read #{payload[:expires].inspect} as a day" if payload[:expires].present? && expires_at.nil?

    framed = if run_task
      "Run #{run_task[:name]}#{" #{delay}s after" if delay.positive?} #{human}"
    elsif timer_seconds.positive?
      "Start a #{Buddy::Timers.humanize_seconds(timer_seconds)} timer #{human}"
    elsif to_self
      "Remind you #{human}"
    else
      "Let #{recipient.first_name} know #{human}"
    end
    framed = "#{framed}, until #{expires_at.strftime("%b %-e")}" if expires_at

    # Deliberately a note rather than a raise: two reminders on one condition
    # ("shower" and "do laundry" when I get home) are perfectly normal. The one
    # that hurts is the one they forgot - a stale deploy watch nobody remembered
    # sat behind a fresh one and a single deploy pinged twice. This runs before
    # the model writes a word, so it can mention it in the same turn.
    twin    = ctx.existing_watch_twin(scope, match, owner: owner, listener: condition.listener)
    warning = twin && "One is ALREADY listening for this: #{twin.body.to_s.truncate(60).inspect}. " \
                      "Setting this leaves both, so both will fire. Say that plainly and offer to " \
                      "retire the old one (cancel_reminder) - don't add a second one silently."

    # Not a twin, but armed on the same trigger. A correction rewrites the
    # listener, so the twin check above structurally cannot see one, and the
    # watch being corrected sits there and fires later anyway.
    siblings = twin ? [] : ctx.sibling_watches(scope, condition.listener, owner: owner)
    if siblings.any?
      bodies  = siblings.map { |w| w.body.to_s.truncate(40).inspect }.join(", ")
      warning = "JUST set on #{scope}, minutes ago: #{bodies}. A different listener is a SEPARATE watch, " \
                "never a replacement. If this one CORRECTS one of those - they said no, not that, or asked " \
                "again for a different event on the same thing - cancel it (cancel_reminder) in this same " \
                "turn and tell them you did. If they're meant to run alongside each other, leave them."
    end

    {
      summary:  ["#{framed}?", warning].compact.join(" "),
      resolved: {
        trigger_scope:  scope,
        match:          match,
        listener:       condition.listener,
        human_when:     human,
        recipient_name: (to_self ? nil : recipient.first_name),
        one_shot:       !every,
        place_known:    place_known != false,
        place_name:     place_name,
        notify_user_id: notify_user&.id,
        watch_owner_id: owner.id,
        run_scope:      run_task&.dig(:scope),
        run_task_name:  run_task&.dig(:name),
        run_delay:      delay,
        timer_seconds:  timer_seconds,
        expires_at_iso: expires_at&.iso8601,
      },
    }
  },
  label: ->(payload, _ctx) {
    "Remind #{payload[:human_when]}: #{payload[:text].to_s.truncate(40)}"
  },
  execute: ->(payload, ctx) {
    # Don't set a location watch we can't actually anchor - a place we couldn't
    # resolve would store a name-only match that never fires. Report it instead
    # so Buddy asks where the place is rather than pretending it's handled.
    return { unknown_place: true, place_name: payload[:place_name] } if payload[:place_known] == false

    # The watch fires for its owner (usually the user; for an agenda watch, the
    # calendar's owner), so it must live under that person and fire into their
    # conversation. Cross-user delivery to notify_user is handled at fire time.
    owner_id = payload[:watch_owner_id].presence || ctx.user.id
    owner    = owner_id.to_i == ctx.user.id ? ctx.user : User.find(owner_id)
    conversation = Buddy::CompanionRelay.conversation_for(owner)

    watch = BuddyWatch.create!(
      user:              owner,
      byte_conversation: conversation,
      notify_user_id:    payload[:notify_user_id],
      kind:              (
        if payload[:run_scope].present?
          "action"
        elsif payload[:timer_seconds].to_i.positive?
          "timer"
        else
          "prompt"
        end
      ),
      body:              payload[:text].to_s.first(500),
      trigger_scope:     payload[:trigger_scope].to_s,
      listener:          payload[:listener].presence,
      match:             payload[:match] || {},
      one_shot:          ActiveModel::Type::Boolean.new.cast(payload[:one_shot]),
      expires_at:        (Time.zone.parse(payload[:expires_at_iso].to_s) if payload[:expires_at_iso].present?),
      metadata:          {
        "human_when"    => payload[:human_when].to_s,
        "run_scope"     => payload[:run_scope].presence,
        "run_task_name" => payload[:run_task_name].presence,
        "run_delay"     => payload[:run_delay].to_i,
        "timer_seconds" => payload[:timer_seconds].to_i.positive? ? payload[:timer_seconds].to_i : nil,
      }.compact,
    )
    {
      watch_id:       watch.id,
      human_when:     payload[:human_when],
      recipient_name: payload[:recipient_name],
      trigger_scope:  watch.trigger_scope,
      listener:       watch.listener,
      run_task_name:  watch.run_task_name,
      run_delay:      watch.run_delay,
      timer_seconds:  watch.timer_seconds,
      expires_at:     watch.expires_at&.iso8601,
    }
  },
  # Setting a watch is safe + reversible (cancel_reminder undoes it), so it
  # runs WITHOUT a confirmation checkbox and drops an activity receipt.
  auto:    true,
  receipt: ->(result, ctx) {
    name = ctx.buddy_name
    if result[:unknown_place]
      where = result[:place_name].to_s.strip
      "Not sure where #{where.presence || "that"} is - what's the address, or is it on your calendar?"
    else
      line = if result[:run_task_name].present?
        after = result[:run_delay].to_i.positive? ? ", #{result[:run_delay]}s after" : ""
        "#{name} will run **#{result[:run_task_name]}** #{result[:human_when]}#{after}"
      elsif result[:timer_seconds].to_i.positive?
        "#{name} will start a #{Buddy::Timers.humanize_seconds(result[:timer_seconds])} timer #{result[:human_when]}"
      elsif result[:recipient_name].present?
        "#{name} will let #{result[:recipient_name]} know #{result[:human_when]}"
      else
        "#{name} will remind you #{result[:human_when]}"
      end
      # A watch that stops on its own has to SAY so. Left off, "every time the
      # doorbell sees somebody" reads as forever, which is the thing they were
      # trying to avoid by bounding it.
      ends = (Time.zone.parse(result[:expires_at].to_s) rescue nil)
      line = "#{line}, until #{ctx.friendly_day(ends)}" if ends
      # A hand-written watch shows what it's really matching underneath. This is
      # the one moment they can catch a listener that's subtly wrong, before it
      # sits there for a month not firing.
      result[:listener].present? ? "#{line}\n`#{result[:listener]}`" : line
    end
  },
)
