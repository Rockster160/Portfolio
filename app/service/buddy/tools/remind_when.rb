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

    **How you write `text` depends on `repeat`, and it matters.** A one-shot
    fires once and you compose the message then, so `text` can be about the
    intent. A REPEATING one is delivered exactly as written, every single time,
    without you in the loop - it's a feed, and a feed doesn't need you to say
    it in a fresh way sixty times a day. So write those as the finished
    sentence they'll read: "Claude list got a new item in Ocs-Backend", not
    "ping me when the Claude list gets an item". Whatever the trigger carries -
    the item, the title - is appended for you, so don't try to write it in.

    Unless they want it somewhere OTHER than the end, which is what a
    `{placeholder}` is for. `{name}` is the thing that changed, and any other
    key reads straight off the trigger, so "{name} landed on the Claude list"
    comes out naming the item mid-sentence and nothing is appended. Use one only
    when they've said where they want it; the plain sentence is the default and
    it's usually right.

    `notify` (optional) redirects the heads-up to a household member instead of
    the user themselves: "whenever I add to our agenda, let Rocco know" →
    notify="Rocco". Their companion delivers it. Omit for an ordinary
    reminder-to-self. Must be someone in the household.

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
    trigger:     { type: :enum,    required: true,  values: %i[arrive depart chore event agenda deploy custom], description: "Condition type" },
    target:      { type: :string,  required: false, description: "Place / chore / event / calendar name the condition is about (omit for deploy and custom)" },
    listener:    { type: :string,  required: false, description: "Jil listener string. Required for trigger=custom, ignored otherwise. Read read_listener_guide first." },
    when_phrase: { type: :string,  required: false, description: "Plain-language meaning of the listener (\"when something is added to the Claude list\"). Required for trigger=custom." },
    repeat:      { type: :boolean, required: false, default: false, description: "Fire every time (true) instead of just the next time (false)" },
    notify:      { type: :string,  required: false, description: "Household member to notify instead of the user (optional)" },
    run:         { type: :string,  required: false, description: "Jil task name to FIRE when the condition hits, instead of saying anything. Verbatim from jil_triggers." },
    delay:       { type: :integer, required: false, description: "Seconds to wait after the condition before running it (max 900). With `run` only." },
  },
  # Watching for an arrival or a deploy is everyone's. The other three reach
  # into a feature: a chore watch would tell someone without chores when the
  # rest of the household finished theirs, which is exactly the visibility the
  # block exists to prevent.
  gated_values: { trigger: { chore: :chores, event: :events, agenda: :agenda } },
  confirm: ->(payload, ctx) {
    trigger = payload[:trigger].to_s
    target  = payload[:target].to_s.strip

    # Most scopes fire for the user themselves; :agenda_item fires for the
    # calendar's OWNER (AgendaItem#user delegates to its agenda), so an agenda
    # watch must be owned by that person to ever fire.
    owner = ctx.user

    scope, match, human, place_known, place_name = case trigger
    when "arrive"
      place = ctx.resolve_place_location(target)
      raise "arrive needs a place (target)" if place["name"].blank?
      ["travel", { "action" => "arrived", "place" => place.except("known") }, "when you get to #{place["name"]}", place["known"], place["name"]]
    when "depart"
      place = ctx.resolve_place_location(target)
      raise "depart needs a place (target)" if place["name"].blank?
      ["travel", { "action" => "departed", "place" => place.except("known") }, "when you leave #{place["name"]}", place["known"], place["name"]]
    when "chore"
      raise "chore needs a chore name (target)" if target.blank?
      name = ctx.resolve_chore(target)&.name || target
      ["chore_completion", { "action" => "completed", "chore_name" => name }, "next time you finish #{name}", true, name]
    when "event"
      raise "event needs an event name (target)" if target.blank?
      ["event", { "action" => "added", "name" => target }, "next time you log #{target}", true, target]
    when "agenda"
      raise "agenda needs a calendar name (target)" if target.blank?
      agenda = ctx.resolve_writable_agenda(target)
      raise "not sure which calendar #{target} is" if agenda.nil?
      owner  = agenda.user
      ["agenda_item", { "action" => "created", "agenda_id" => agenda.id }, "when something's added to #{agenda.name}", true, agenda.name]
    when "deploy"
      # Phrased without "next" so the repeating form reads "every time a deploy
      # finishes" rather than "every time the NEXT deploy finishes".
      ["deploy", {}, "when a deploy finishes", true, nil]
    when "custom"
      listener = payload[:listener].to_s.strip
      raise "custom needs a `listener` - read read_listener_guide first" if listener.blank?

      unless ::Jil::ListenerMatch.valid?(listener, user: ctx.user)
        named = ::Jil::ListenerMatch.scope_of(listener)
        raise(
          if named && !::Jil::ListenerMatch.known_scope?(named, user: ctx.user)
            "nothing here has ever fired a #{named.inspect} trigger, so that listener could " \
              "never fire - call read_listener_guide and use a scope off the real list"
          else
            "#{listener.inspect} isn't a listener that could ever fire"
          end,
        )
      end

      # The person reads the plain phrasing; the listener rides underneath as
      # detail (see `listener` on the resolved payload). Showing them the raw
      # syntax as the whole description tells them nothing they asked about,
      # but dropping it entirely makes an unexpected fire unexplainable.
      phrase = payload[:when_phrase].to_s.strip
      raise "custom needs a `when_phrase` saying what that listener means in their words" if phrase.blank?

      [::Jil::ListenerMatch.scope_of(listener), {}, phrase.sub(/\A(when|whenever)\s+/i, "when "), true, nil]
    else
      raise "unknown trigger #{trigger.inspect}"
    end

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

    every = ActiveModel::Type::Boolean.new.cast(payload[:repeat])
    human = human.sub(/\Awhen /, "every time ").sub(/\Anext time /, "every time ") if every

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

    framed = if run_task
      "Run #{run_task[:name]}#{" #{delay}s after" if delay.positive?} #{human}"
    elsif to_self
      "Remind you #{human}"
    else
      "Let #{recipient.first_name} know #{human}"
    end

    # Deliberately a note rather than a raise: two reminders on one condition
    # ("shower" and "do laundry" when I get home) are perfectly normal. The one
    # that hurts is the one they forgot - a stale deploy watch nobody remembered
    # sat behind a fresh one and a single deploy pinged twice. This runs before
    # the model writes a word, so it can mention it in the same turn.
    twin    = ctx.existing_watch_twin(scope, match, owner: owner, listener: (payload[:listener].to_s.strip.presence if trigger == "custom"))
    warning = twin && "One is ALREADY listening for this: #{twin.body.to_s.truncate(60).inspect}. " \
                      "Setting this leaves both, so both will fire. Say that plainly and offer to " \
                      "retire the old one (cancel_reminder) - don't add a second one silently."

    {
      summary:  ["#{framed}?", warning].compact.join(" "),
      resolved: {
        trigger_scope:  scope,
        match:          match,
        listener:       (payload[:listener].to_s.strip.presence if trigger == "custom"),
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
      kind:              payload[:run_scope].present? ? "action" : "prompt",
      body:              payload[:text].to_s.first(500),
      trigger_scope:     payload[:trigger_scope].to_s,
      listener:          payload[:listener].presence,
      match:             payload[:match] || {},
      one_shot:          ActiveModel::Type::Boolean.new.cast(payload[:one_shot]),
      metadata:          {
        "human_when"    => payload[:human_when].to_s,
        "run_scope"     => payload[:run_scope].presence,
        "run_task_name" => payload[:run_task_name].presence,
        "run_delay"     => payload[:run_delay].to_i,
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
      elsif result[:recipient_name].present?
        "#{name} will let #{result[:recipient_name]} know #{result[:human_when]}"
      else
        "#{name} will remind you #{result[:human_when]}"
      end
      # A hand-written watch shows what it's really matching underneath. This is
      # the one moment they can catch a listener that's subtly wrong, before it
      # sits there for a month not firing.
      result[:listener].present? ? "#{line}\n`#{result[:listener]}`" : line
    end
  },
)
