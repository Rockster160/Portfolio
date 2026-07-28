Buddy::Tools.register(
  name:        :remind_when,
  description: <<~TXT,
    Set a reminder that fires when a real-world CONDITION happens, not at a
    clock time. Use for "remind me to X when / the next time I <arrive /
    leave / do> Y". For plain time-based reminders use schedule_reminder.

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
      "deploy" - when the next Portfolio deploy finishes. No `target`.

    `text` is what to remind them of, phrased as the nudge itself. It fires
    ONCE by default (the next time the condition happens). Set `repeat`
    true only if they clearly want it every time ("every time I get home...").
    When it fires you'll compose a fresh in-character message, so keep
    `text` about the intent, not the exact words.

    IMPORTANT for places (arrive/depart): the system resolves the place from
    the person's contacts and calendar. You do NOT know in advance whether it
    can - so don't state the reminder is set in your own words, and don't
    claim to know where a place is. Let the receipt confirm. If the place
    can't be resolved, the receipt says so and you should then ask where it
    is (an address, or "it's on my calendar"). Don't explain HOW arrival is
    detected - just that you'll let them know.
  TXT
  args: {
    text:    { type: :string,  required: true,  description: "What to remind them of" },
    trigger: { type: :enum,    required: true,  values: %i[arrive depart chore event deploy], description: "Condition type" },
    target:  { type: :string,  required: false, description: "Place / chore / event name the condition is about (omit for deploy)" },
    repeat:  { type: :boolean, required: false, default: false, description: "Fire every time (true) instead of just the next time (false)" },
  },
  confirm: ->(payload, ctx) {
    trigger = payload[:trigger].to_s
    target  = payload[:target].to_s.strip

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
    when "deploy"
      ["deploy", {}, "when the next deploy finishes", true, nil]
    else
      raise "unknown trigger #{trigger.inspect}"
    end

    every = ActiveModel::Type::Boolean.new.cast(payload[:repeat])
    human = human.sub(/\Awhen /, "every time ").sub(/\Anext time /, "every time ") if every

    {
      summary:  "Remind you #{human}?",
      resolved: {
        trigger_scope: scope,
        match:         match,
        human_when:    human,
        one_shot:      !every,
        place_known:   place_known != false,
        place_name:    place_name,
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

    conversation = ctx.user.byte_conversations.where(mode: :buddy).order(last_message_at: :desc).first ||
                   ctx.user.byte_conversations.order(last_message_at: :desc).first
    raise "no conversation to fire into" if conversation.nil?

    watch = BuddyWatch.create!(
      user:              ctx.user,
      byte_conversation: conversation,
      kind:              "prompt",
      body:              payload[:text].to_s.first(500),
      trigger_scope:     payload[:trigger_scope].to_s,
      match:             payload[:match] || {},
      one_shot:          ActiveModel::Type::Boolean.new.cast(payload[:one_shot]),
      metadata:          { "human_when" => payload[:human_when].to_s },
    )
    { watch_id: watch.id, human_when: payload[:human_when], trigger_scope: watch.trigger_scope }
  },
  # Setting a watch is safe + reversible (cancel_reminder undoes it), so it
  # runs WITHOUT a confirmation checkbox and drops an activity receipt.
  auto:    true,
  receipt: ->(result, ctx) {
    name = ctx.user.buddy_theme.to_s == "moss" ? "Moss" : "Byte"
    if result[:unknown_place]
      where = result[:place_name].to_s.strip
      "Not sure where #{where.presence || "that"} is - what's the address, or is it on your calendar?"
    else
      "#{name} will remind you #{result[:human_when]}"
    end
  },
)
