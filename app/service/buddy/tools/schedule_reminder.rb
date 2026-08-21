Buddy::Tools.register(
  name:        :schedule_reminder,
  description: <<~TXT,
    Schedule a nudge to fire at a future local time. Use when the person
    says "remind me to X at Y", "at 3pm ping me about the vet appt",
    "in an hour tell me to check the oven", etc.

    A reminder arrives once and is gone. If they said "agenda", "calendar",
    or asked for a TASK, they want a row they can see and check off - that's
    `add_agenda_item`, and a reminder is not a substitute for it.

    **A REPEAT THEY HAVE TO ACT ON EACH TIME IS `set_timer(repeat: true)`, NOT
    THIS.** "Check the printer every 30 minutes", "get me back to the cupboards
    every half hour", "make me drink water every hour" - each round asks them
    to go and DO something, and the next round should start when they've done
    it. That's a countdown with a button on the end, which is what set_timer's
    `repeat` builds. Set it here instead and it fires on the clock whether or
    not they acted, so fourteen nudges stack up while they're away from the
    thing. This tool is for a nudge that's true whether or not they're there:
    "remind me at 9", "every Wednesday night", "in an hour".

    **`text` is what they'll READ when it goes off, not what they said to get
    it set.** Their words are a request aimed at you; the reminder is a nudge
    aimed at them, and the two are almost never the same sentence. "Please ping
    me when it's time to do that!" stored verbatim arrives at noon as "Reminder:
    Ping me when it's time to do the plant check." - a message asking them to
    ask you, at the moment they were supposed to be told what to do (prod 3449).
    Write the thing itself: "Check the bamboo and water the plants."

    `notify` aims it at SOMEBODY ELSE in the house, and that makes it a MESSAGE
    from this person that leaves later. "Send Chelsea a cute note in 10
    minutes", "remind Eve at 4 that...", "ping mom tonight about..." - name them
    here and `text` reaches them at that time as words from the person asking,
    delivered exactly the way `message_partner` delivers one now. So write
    `text` as the finished note they'll read, not as an instruction about them.

    Read who it's FOR, not just what it says: "send a reminder to Chelsea that
    we need to X" is Chelsea's, and setting it for yourself instead means the
    person who was supposed to act never hears about it. The row still belongs
    to whoever asked, so they can see and cancel it before it goes. Leave
    `notify` off for themselves.

    With `notify`, `at` comes from WHEN THEY SAID TO SEND IT and from nowhere
    else. A time inside the note is part of the note. "Tell Rocco I'll make
    supper at 6:00" is a message to pass along right now that happens to
    mention 6:00 - taking the 6:00 as the send time delivers the news at the
    moment it stops being news, which is what happened in prod 3303. If the
    only clock time in the request sits inside what they want said, this is the
    wrong tool: use `message_partner`.

    This is the LATER form. To tell someone something right now, that's
    `message_partner`; to send it when something HAPPENS rather than at a time
    ("when someone's at the door", "next time a deploy finishes"), that's
    `remind_when` with its own `notify`.

    A reminder is a message they have to be LOOKING at. If they said ALARM, or
    the whole point is being interrupted - waking up, leaving on time - use
    `alarm`, which rings out loud until it's acknowledged. It reaches 24 hours
    ahead; further out, or on a recurrence, this is still the tool.

    **Never alongside an alarm for the same moment.** "Wake me at 6:30
    tomorrow" came back as an alarm AND one of these, and the reply then
    described the reminder - "wake-up reminder's set" - so the thing that would
    actually wake them went unmentioned and the thread carried a duplicate that
    fires beside it. Pick the one that does the job and say what it is.

    ONE-SHOT: pass `at` (ISO-8601 datetime with timezone offset).
    Convert natural-language times ("in 30 min", "3pm", "tomorrow
    morning") into ISO using the local time in RIGHT NOW block.

    RECURRING: pass `repeat` to fire the reminder on a schedule instead
    of just once. Use for "check in with me every day at 9", "remind me
    to take the trash out every Wednesday night", etc. `repeat` accepts:
      "daily:HH:MM"                  - every day at HH:MM
      "weekdays:HH:MM"               - Mon-Fri at HH:MM
      "weekly:<days>:HH:MM"          - "weekly:wednesday:20:00", and more
                                       than one is fine: "weekly:mon,wed,fri:07:30"
      "monthly:<day-of-month>:HH:MM" - e.g. "monthly:1:09:00"
      "monthly:<nth>-<weekday>:HH:MM" - the Nth weekday of the month, where
                                       nth is 1-4 or "last": "monthly:2-tuesday:10:00"
                                       is the SECOND TUESDAY of every month
      "every:<n>-<unit>:HH:MM"       - every N minutes / hours / days / weeks /
                                       months, counting from today:
                                       "every:2-weeks:10:00" is every OTHER
                                       week on today's weekday, and
                                       "every:30-minutes:14:00" nudges every
                                       half hour from 2pm to the end of the day
      "yearly:HH:MM"                 - once a year, on today's date

    "Every second Tuesday" is two different requests and they aren't the
    same days - the second Tuesday OF THE MONTH is
    "monthly:2-tuesday:HH:MM", every OTHER Tuesday is "every:2-weeks:HH:MM"
    set on a Tuesday. Ask which they meant if it isn't clear.

    When `repeat` is set, `at` is optional (the first fire computes
    from the recurrence). If both are set, `at` is the first fire and
    the recurrence takes over from then on. `until` (a plain date,
    YYYY-MM-DD) stops it repeating after that day.

    `kind` controls what happens at fire time:
      "reminder" (default) - plain text nudge + push notification.
      "prompt" - fresh Buddy turn triggered with `text` as the seed.
        Use for "check in with me every day at 9" where you want Buddy
        to compose a fresh check-in each time, not repeat the exact
        same words.

    **A reminder whose text contains an "if" needs a check, or the "if" is
    decorative.** "Charge the car if the chore isn't done yet" with no check is
    a sentence the person reads at 9pm whether or not they already did it, and
    it will say the same thing again at 10. Whenever what they said carries a
    condition, put the condition in the arguments. Two ways to ask:

    SEARCH - does anything match?

      check:        which set to look in (see the enum: chore_completions,
                    action_events, agenda_items, chores, emails, contacts,
                    boxes)
      check_query:  a search in the ordinary query syntax - the same one the
                    app searches everything with
      check_expect: `missing` to fire only while the search finds NOTHING
                    (the "if it isn't done yet" shape), `found` for the
                    opposite ("once I've logged a workout, ...")

    **QUOTE ANY VALUE CONTAINING A SPACE.** `name:"Charge Villager Car"` is one
    term; `name:Charge Villager Car` is `name:Charge` plus two loose words, and
    matches things nobody asked about. This is the single easiest way to write
    a condition that looks right and answers the wrong question.

    Use RELATIVE windows - `is:today`, `is:yesterday`, `is:week`. A written-out
    date is fixed to the day you wrote it and means nothing on the day it runs.

    ASK ONE OF THEIR OWN TASKS - anything they've wired, they can gate on:

      check_task: the name of a Jil FUNCTION from `jil_functions`, run when the
                  reminder comes due. Whatever it returns decides: empty,
                  `false`, `0`, `no`, `off`, `none` and `unknown` are NO, and
                  anything else is YES.
      check_expect: `truthy` (default) or `falsy`.

    Same rule as `call_jil_function`: only ever name a function that CHECKS or
    REPORTS. One that opens, closes, sets or starts something will do that every
    time the reminder comes due.

    A skipped reminder says nothing at all - that's the point of it - but it
    leaves a small receipt saying what it checked, and it still records that it
    came due, so they can ask whether it went off.

    **Repeating WITHIN a day** has two ways in and they build the same rule.
    `repeat: "every:30-minutes:14:00"` is the short one and runs to the end of
    the day; add `until` (a date) to stop it after today. When they named an
    hour to STOP, use `every_minutes` + `until_time` on top of a `repeat`
    instead: "nudge me hourly from 9 to 11 tonight" is `repeat: daily:21:00`,
    `every_minutes: 60`, `until_time: "23:00"`, `until` today.

    Either way it is ONE reminder, never three an hour apart. Three rows can't
    be cancelled together, can't be edited together, and each one nags again
    after the person has already dealt with it.

    **A repeat that should stop when something HAPPENS** - "check the printer
    every 30 minutes until the print finishes", "nudge me hourly until I get
    home" - is `stop_when`, on the same call. It takes the same conditions
    `remind_when` does, and when that condition trips the reminder is switched
    off for good and they're told it stopped. **This is not a thing you lack** -
    never answer one of these with "I can't make it stop by itself".

    `stop_when` is the whole rule ending. `check` / `check_task` are a
    different question: they decide whether ONE firing speaks, so a reminder
    with a check stays alive and asks again tomorrow. Use a check to skip, and
    `stop_when` to finish.

    A reminder can also RUN something instead of saying it. Write `text` as
    "run <name>" (or trigger / fire / start) naming one of their saved routines
    or a Jil task, and that's what happens when it comes due - no message, just
    the thing. "Every weekday at 7, run my morning routine" is this. It's
    resolved when it FIRES, so a name that stops matching quietly goes back to
    being an ordinary nudge rather than running the nearest thing to it.
  TXT
  args: {
    text:   {
      type:        :string,
      required:    true,
      description: "What to remind them of. ALWAYS name the thing itself - this fires hours or " \
                   "days later, out of any context, and it is the whole message they get. " \
                   "\"Leave for the dentist\" over \"time to go\"; \"Get ready for the 1:40 " \
                   "doctor appointment\" over \"get ready\". A nudge that doesn't say what it " \
                   "is for makes them come and ask you.",
    },
    at:     { type: :string, required: false, description: "First fire time (ISO datetime). Required for one-shot." },
    repeat: { type: :string, required: false, description: "Recurrence spec: daily:HH:MM / weekdays:HH:MM / weekly:<days>:HH:MM / monthly:<dom>:HH:MM / monthly:<nth>-<weekday>:HH:MM / every:<n>-<unit>:HH:MM / yearly:HH:MM" },
    until:  { type: :string, required: false, description: "Stop repeating after this date (YYYY-MM-DD)" },
    every_minutes: { type: :integer, required: false, description: "Repeat WITHIN the day this often, starting at the repeat spec's time" },
    until_time:    { type: :string,  required: false, description: "Stop repeating for the day at this time (HH:MM). Needs every_minutes." },
    stop_when:     {
      type:        :enum,
      required:    false,
      values:      Buddy::WatchCondition::TRIGGERS,
      description: "Switch the whole reminder off when this HAPPENS - \"until the print finishes\", " \
                   "\"until I get home\". Needs a repeat; the same conditions remind_when takes",
    },
    stop_target:   { type: :string, required: false, description: "Place / chore / event / calendar name the stop condition is about. With stop_when." },
    stop_listener: { type: :string, required: false, description: "Jil listener string, for stop_when=custom. Read read_listener_guide first." },
    stop_phrase:   { type: :string, required: false, description: "Plain-language meaning of the stop listener. Required for stop_when=custom." },
    check:        { type: :enum,   required: false, values: ScheduleCondition.sets, description: "Records to search before firing" },
    check_query:  { type: :string, required: false, description: "Search that decides it. QUOTE any value with a space: name:\"Some Thing\"" },
    check_task:   { type: :string, required: false, description: "Jil function to ask instead of searching. Must only read/report." },
    check_expect: { type: :enum,   required: false, values: %i[found missing truthy falsy], description: "found/missing for a search, truthy/falsy for a task" },
    kind:   { type: :enum,   required: false, default: :reminder, values: %i[reminder prompt] },
    notify: { type: :string, required: false, description: "Household member this reminder is FOR, if not the person asking" },
  },
  confirm: ->(payload, ctx) {
    recurrence_hash = Buddy::RepeatSpec.parse(
      payload[:repeat],
      on:  ctx.user.perceived_today,
      now: Time.current.in_time_zone(ctx.user.timezone),
    )
    if payload[:repeat].to_s.strip.present? && recurrence_hash.nil?
      raise "unknown repeat spec #{payload[:repeat].inspect}"
    end

    if recurrence_hash && payload[:until].to_s.strip.present?
      ends = (Date.parse(payload[:until].to_s) rescue nil)
      raise "couldn't read #{payload[:until].inspect} as a date" if ends.nil?

      recurrence_hash = recurrence_hash.merge("until_on" => ends.iso8601)
    end

    # The intraday window. Refused without a repeat spec to hang off, because
    # `at` is where it starts and that's the repeat's to give - "every 30
    # minutes" with no day pattern behind it is a rule with no beginning.
    if payload[:every_minutes].to_i.positive? || payload[:until_time].to_s.strip.present?
      raise "an every_minutes window needs a `repeat` to start from" if recurrence_hash.nil?
      raise "every_minutes and until_time go together - one alone does nothing" unless
        payload[:every_minutes].to_i.positive? && payload[:until_time].to_s.strip.present?

      window_end = payload[:until_time].to_s.strip
      raise "couldn't read #{window_end.inspect} as a time (want HH:MM)" unless window_end.match?(/\A\d{1,2}:\d{2}\z/)
      raise "#{window_end} is not after #{recurrence_hash["at"]}" if window_end <= recurrence_hash["at"].to_s

      recurrence_hash = recurrence_hash.merge(
        "every_minutes" => payload[:every_minutes].to_i,
        "until_at"      => window_end,
      )
    end

    # The condition that ENDS it. Resolved here, in front of the person, for the
    # same reason an action watch resolves its task here: a stop rule that can't
    # be built has to fail while somebody is still in the conversation, not
    # silently leave a repeat running forever.
    # And it DEGRADES rather than raising, which is the whole difference
    # between this working and not. A stopping rule that can't be built is a
    # reason to set the repeat without one and say so — not a reason to abandon
    # the repeat, which was fine. Raising here took the half that worked down
    # with the half that didn't, and the person got nothing (dev 4085-4087).
    #
    # The failure travels in the result instead, so the model reads "the
    # reminder is set, the ending is NOT" before it says a word.
    stop_condition = nil
    stop_error     = nil
    if payload[:stop_when].to_s.strip.present?
      begin
        raise "a repeating reminder is what a stopping condition ends, and there isn't one here" if recurrence_hash.nil?

        arg, feature = Buddy::Features.gated_arg(ctx.user, { gated_values: { stop_when: Buddy::WatchCondition::GATED } }, payload)
        raise "watching for that needs #{Buddy::Features.label_for(feature)}" if arg

        stop_condition = Buddy::WatchCondition.resolve(
          {
            trigger:     payload[:stop_when],
            target:      payload[:stop_target],
            listener:    payload[:stop_listener],
            when_phrase: payload[:stop_phrase],
          },
          ctx,
        )
      rescue StandardError => e
        stop_error = e.message
      end
    end

    # An event ending means there is NO daily window. A sub-day repeat needs
    # `until_at` for the fire path to step at all (BuddyReminder#slots_on), and
    # the placeholder end-of-day it gets became a promise: "every 30 min from
    # 5:39pm to 11:59pm" over a rule that was supposed to run until a print
    # finished. Worse than cosmetic - it also stopped at midnight and picked up
    # again at 5:39pm, so an overnight print went unchecked for seventeen hours.
    #
    # Round the clock instead, and let the watch be the ending. `all_day?` in
    # Buddy::ReminderPresenter is what keeps that out of the prose.
    if stop_condition && recurrence_hash && recurrence_hash["every_minutes"].to_i.positive?
      recurrence_hash = recurrence_hash.merge("at" => "00:00", "until_at" => "23:59")
    end

    # Validated HERE rather than at fire time. A condition that can't be
    # evaluated is an authoring mistake, and the moment to catch one is while
    # the person is still in the conversation - not at 9pm three weeks later,
    # when the only symptom is a reminder that quietly never came.
    raise "a check is either a search or a task, not both" if payload[:check].present? && payload[:check_task].present?

    condition = ScheduleCondition.normalize({
      find:   payload[:check],
      query:  payload[:check_query],
      task:   payload[:check_task],
      expect: payload[:check_expect],
    })
    # Run it once, here. A search that blows up in SQL, a task name that
    # resolves to nothing, a value that needed quoting - all of it surfaces in
    # the conversation rather than at 9pm three weeks later, where the only
    # symptom is a reminder that quietly never came.
    #
    # Deliberately not run for a `jil` check: asking a function is not free, and
    # a reminder set for next Tuesday would fire it today just to prove it can.
    # `resolve_task` still runs, which is the half that can be wrong forever.
    if condition
      condition[:kind] == :jil ? ScheduleCondition.resolve_task(condition[:task], ctx.user) :
                                 ScheduleCondition.met?(condition, user: ctx.user)
    end

    fire_at = ctx.resolve_time(payload[:at]) if payload[:at].to_s.strip.length > 0
    # If recurring and no explicit `at`, compute the first fire from the
    # recurrence spec.
    if fire_at.nil? && recurrence_hash
      dummy = BuddyReminder.new(user: ctx.user, recurrence: recurrence_hash)
      fire_at = dummy.next_fire_at(from: Time.current)
    end
    raise "couldn't determine a fire time" if fire_at.nil?
    raise "fire time is in the past" if fire_at < Time.current

    when_str = fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")

    # Who it's FOR. Naming someone we can't place is refused rather than
    # quietly aimed back at the asker - a reminder that reaches the wrong
    # person is the failure this argument exists to stop (prod 2547).
    wanted      = payload[:notify].to_s.strip
    recipient   = wanted.present? ? ctx.resolve_household_user(wanted) : nil
    raise "I'm not sure who #{wanted} is" if wanted.present? && recipient.nil?

    notify_user = recipient && recipient.id != ctx.user.id ? recipient : nil

    # Refusing rather than quietly merging: if this really is a second, separate
    # thing at the same minute, silently folding it into the first would lose a
    # reminder they asked for. Told about it, Buddy can say it's already set, or
    # cancel and re-set if the wording is meant to replace it.
    if recurrence_hash.nil? && notify_user.nil? && (clash = BuddyReminder.clashing(ctx.user, payload[:text], fire_at))
      raise "#{clash.body.inspect} is already set for #{when_str} - nothing new to add"
    end

    summary = if notify_user && recurrence_hash
      "Send this to #{notify_user.first_name} repeatedly, starting #{when_str}?"
    elsif notify_user
      "Send this to #{notify_user.first_name} at #{when_str}?"
    elsif recurrence_hash
      "Repeating reminder for you starting #{when_str}?"
    else
      "Remind you at #{when_str}?"
    end
    summary = "#{summary.chomp("?")}, #{ScheduleCondition.describe(condition)}?" if condition
    summary = "#{summary.chomp("?")}, #{stop_condition.human}?" if stop_condition
    {
      summary:  summary,
      resolved: {
        fire_at_iso:    fire_at.iso8601,
        recurrence:     recurrence_hash,
        condition:      condition,
        notify_user_id: notify_user&.id,
        recipient_name: notify_user&.first_name,
        stop_scope:     stop_condition&.scope,
        stop_match:     stop_condition&.match,
        stop_listener:  stop_condition&.listener,
        stop_human:     stop_condition&.human,
        stop_error:     stop_error,
      }.compact,
    }
  },
  label: ->(payload, ctx) {
    fire_at  = Time.zone.parse(payload[:fire_at_iso].to_s) rescue nil
    when_str = fire_at ? fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p") : payload[:at].to_s
    sub      = payload[:recurrence] ? "repeats #{payload[:repeat] || payload.dig(:recurrence, 'kind')}" : when_str
    sub      = "to #{payload[:recipient_name]} · #{sub}" if payload[:recipient_name].present?
    { title: payload[:text].to_s.truncate(60), sub: sub.presence }
  },
  execute: ->(payload, ctx) {
    fire_at = Time.zone.parse(payload[:fire_at_iso].to_s) || ctx.resolve_time(payload[:at])
    # The thread it will FIRE into, which is a question about weeks from now
    # rather than about this moment — so it's the primary one, not whichever
    # happened to be open when they asked. Falls back to any thread at all,
    # since a reminder with nowhere to land is worse than one in the wrong place.
    conversation = ByteConversation.for_self_initiated(ctx.user) ||
                   ctx.user.byte_conversations.order(last_message_at: :desc).first
    raise "no conversation to fire into" if conversation.nil?

    reminder = BuddyReminder.create!(
      user:              ctx.user,
      byte_conversation: conversation,
      notify_user_id:    payload[:notify_user_id],
      kind:              (payload[:kind] || :reminder).to_s,
      body:              payload[:text].to_s.first(500),
      fire_at:           fire_at,
      recurrence:        payload[:recurrence],
      condition:         payload[:condition],
    )
    # The rule that ends it. A one-shot watch, armed on the same condition
    # machinery `remind_when` uses — it fires once, switches the reminder off
    # and says so.
    stopper = nil
    if payload[:stop_scope].present?
      stopper = BuddyWatch.create!(
        user:              ctx.user,
        byte_conversation: conversation,
        kind:              :cancel,
        trigger_scope:     payload[:stop_scope],
        listener:          payload[:stop_listener],
        match:             payload[:stop_match] || {},
        body:              payload[:stop_human].to_s.presence || "That's done",
        one_shot:          true,
        metadata:          { "cancels_reminder_id" => reminder.id, "human_when" => payload[:stop_human].to_s },
      )
    end

    {
      reminder_id:    reminder.id,
      fire_at:        fire_at.iso8601,
      recurrence:     payload[:recurrence],
      recipient_name: payload[:recipient_name],
      stop_watch_id:  stopper&.id,
      stop_human:     payload[:stop_human],
      # Said in as many words, because the one thing that must not happen next
      # is the reply describing an ending that isn't there.
      stop_failed:    (
        if payload[:stop_error].present?
          "THE REMINDER IS SET. The stopping rule is NOT: #{payload[:stop_error]}. " \
            "Say both - what you set, and that it won't stop on its own yet - and offer " \
            "`request_feature` for the ending. Never describe a stopping rule you haven't set."
        end
      ),
    }.compact
  },
  # Scheduling a reminder is safe + reversible, so it runs WITHOUT a
  # confirmation checkbox and drops an activity receipt instead.
  auto:    true,
  # Who it's for leads the receipt when it isn't them. "Byte will send you a
  # reminder at 12:22pm" was the only visible sign that a reminder meant for
  # Chelsea had been aimed back at the person who asked, and it's easy to read
  # past (prod 2547). It says "send" rather than "remind" for the same reason
  # the delivery bridges: aimed at somebody else, this is a note going to them.
  receipt: ->(result, ctx) {
    name    = ctx.buddy_name
    fire_at = (Time.zone.parse(result[:fire_at].to_s) rescue nil)
    rec     = result[:recurrence]
    who     = result[:recipient_name].presence

    # The chip has to carry the ending, or the one thing they'd want to correct
    # is the one thing not written down.
    stops = (", #{Buddy::WatchCondition.until_phrase(result[:stop_human])}" if result[:stop_watch_id].present? && result[:stop_human].present?)
    stops ||= " (won't stop on its own)" if result[:stop_failed].present?

    if rec.is_a?(Hash)
      hhmm  = (Time.zone.parse(rec["at"].to_s) rescue nil)
      tstr  = hhmm ? hhmm.strftime("%-I:%M%P").sub(":00", "") : rec["at"].to_s
      ends  = rec["until_on"].present? ? " until #{rec["until_on"]}" : ""
      verb  = who ? "send this to #{who}" : "remind you"
      # An intraday rule has a start AND an end to its day, and "at 5:19pm"
      # names only the first of fourteen fires. Unless it runs round the clock,
      # in which case it has no window to name and saying one is the lie.
      shut  = (Time.zone.parse(rec["until_at"].to_s)&.strftime("%-I:%M%P")&.sub(":00", "") rescue nil)
      band  = (
        if Buddy::ReminderPresenter.all_day?(rec) then ""
        elsif rec["every_minutes"].to_i.positive? && shut then " from #{tstr} to #{shut}"
        end
      )

      "#{name} will #{verb} #{Buddy::ReminderPresenter.repeat_phrase(rec)}#{band || " at #{tstr}"}#{ends}#{stops}"
    elsif who
      "#{name} will send this to #{who} #{ctx.friendly_future(fire_at)}"
    else
      "#{name} will send you a reminder #{ctx.friendly_future(fire_at)}"
    end
  },
)
