Buddy::Tools.register(
  name:        :schedule_trigger,
  description: <<~TXT,
    Put a raw Jil TRIGGER on the clock, optionally behind a check.

    "If I've done the villager car by 8, fire `villager:car:charged`" is this:
    at 8 it looks, and it fires only if the answer says so.

    ## This is not `trigger_jil_task`

    That one fires a task BY NAME and can only reach the tasks in your
    `jil_triggers` list. This one publishes a raw scope onto the listener bus.
    Nothing is resolved, nothing is named, and **it does not matter whether you
    have access to whatever is listening** - a trigger is an announcement, not a
    call. Anything of theirs listening for that scope, whose filter the data
    satisfies, runs. If nothing is listening, nothing happens and that is fine.

    So use this when they give you a SCOPE - something shaped like
    `some:jil:listener` - rather than the name of an automation. When they name
    an automation they want to happen right now, that's `trigger_jil_task`.

    ## Arguments

      scope:  the listener scope. Colons are fine and are read the way a
              listener reads them: the first segment is the scope, the rest is
              the filter data. `villager:car:charged` fires scope `villager`
              with `car:charged`.
      data:   extra `key:value` pairs, or a JSON object when a value has spaces
              or colons in it. Merged over anything parsed out of `scope`.
      at:     when to fire (ISO datetime). Required.

    ## The check

    Same shape as `schedule_reminder`, and the reason to reach for this at all:

      check / check_query / check_expect  - a search. QUOTE ANY VALUE WITH A
              SPACE: `name:"Charge Villager Car"` is one term, and
              `name:Charge Villager Car` is a term plus two loose words that
              match things nobody asked about.
      check_task / check_expect           - ask one of their Jil functions
              instead, and read what it says.
      check_place / check_expect          - where they ARE when it fires.
              `at` or `away`. The place defaults to home, which is what
              somebody means when they name no place at all.

    "if I've done X by 8" is `check: chore_completions`,
    `check_query: 'name:"X" is:today'`, `check_expect: found` - fire only when
    the completion IS there. "if I still haven't" is the same with `missing`.

    "if I'm not back by 12:50" is `check_place: home`, `check_expect: away`.
    A sentence that says "if I'm not home" is a CHECK, not a hedge - setting
    the time half and leaving the condition out is a different instruction from
    the one they gave.

    Without a check this is just a delayed trigger, which is fine and is what a
    plain "fire X at 8" means.

    A trigger that fails its check announces nothing, but leaves a small receipt
    saying what it looked at, so a check that's quietly wrong is visible.
  TXT
  feature:     :jil,
  args:        {
    scope:        { type: :string, required: true,  description: "Listener scope to fire, e.g. villager:car:charged" },
    data:         { type: :string, required: false, description: "Extra key:value data, or a JSON object" },
    at:           { type: :string, required: true,  description: "When to fire (ISO datetime)" },
    check:        { type: :enum,   required: false, values: ScheduleCondition.sets, description: "Records to search before firing" },
    check_query:  { type: :string, required: false, description: "Search that decides it. QUOTE any value with a space." },
    check_task:   { type: :string, required: false, description: "Jil function to ask instead of searching. Must only read/report." },
    check_place:  { type: :string, required: false, description: "Check where they are instead. A place name, or home." },
    check_expect: { type: :enum,   required: false, values: %i[found missing truthy falsy at away], description: "found/missing for a search, truthy/falsy for a task, at/away for a place" },
  },
  auto:        true,
  confirm:     ->(payload, ctx) {
    # A listener reads `scope:rest` as a scope plus a filter, and that's how
    # people say one out loud too - "fire villager:car:charged" is one string,
    # not two arguments. Splitting here means the tool accepts what they said
    # verbatim instead of asking the model to take it apart first.
    scope, embedded = payload[:scope].to_s.strip.split(":", 2)
    raise "a trigger needs a scope to fire" if scope.blank?

    data = {}
    data = data.merge(::Tokenizing::TriggerData.parse(embedded, as: ctx.user)) if embedded.present?
    data = data.merge(::Tokenizing::TriggerData.parse(payload[:data], as: ctx.user)) if payload[:data].present?

    fire_at = ctx.resolve_time(payload[:at])
    raise "couldn't work out when to fire that" if fire_at.nil?
    raise "that time has already passed" if fire_at < Time.current

    checks = payload.values_at(:check, :check_task, :check_place).count(&:present?)
    raise "a check is a search, a task or a place - not more than one" if checks > 1

    condition = ScheduleCondition.normalize({
      kind:   (:location if payload[:check_place].present?),
      find:   payload[:check],
      query:  payload[:check_query],
      task:   payload[:check_task],
      place:  payload[:check_place],
      expect: payload[:check_expect],
    })
    # Validated on the way in, same as schedule_reminder: a search that won't
    # run, or a task name that resolves to nothing, is an authoring mistake, and
    # the moment to catch one is while the person is still here. A `jil` check
    # is resolved but NOT run - asking a function isn't free, and one scheduled
    # for next week shouldn't fire today to prove it can.
    #
    # A `location` check resolves the PLACE and stops there, for the same reason
    # in the other direction: running it needs a position the phone may not have
    # reported yet, and "we don't know where you are right now" is no reason to
    # refuse to schedule something for 12:50. A place that resolves to nothing
    # IS an authoring mistake and is caught here.
    if condition && condition[:kind] == :jil
      ScheduleCondition.resolve_task(condition[:task], ctx.user)
    elsif condition && condition[:kind] == :location
      ScheduleCondition.validate_place!(condition, ctx.user)
    elsif condition
      ScheduleCondition.met?(condition, user: ctx.user)
    end

    when_str = Buddy::Clock.day_at(fire_at, zone: ctx.user.timezone)
    summary  = "Fire `#{scope}` #{when_str}?"
    summary += " (#{data.map { |k, v| "#{k}: #{v}" }.join(", ")})" if data.any?
    summary  = "#{summary.chomp("?")}, #{ScheduleCondition.describe(condition)}?" if condition

    {
      summary:  summary,
      resolved: {
        scope:        scope,
        trigger_data: data,
        fire_at_iso:  fire_at.iso8601,
        condition:    condition,
      }.compact,
    }
  },
  label:       ->(payload, ctx) {
    fire_at = (Time.zone.parse(payload[:fire_at_iso].to_s) rescue nil)
    subs = [fire_at ? Buddy::Clock.day_at(fire_at, zone: ctx.user.timezone) : payload[:at].to_s]
    subs << ScheduleCondition.describe(payload[:condition])
    { title: payload[:scope].to_s, sub: subs.compact_blank.join("\n").presence }
  },
  execute:     ->(payload, ctx) {
    # Through Jil::Schedule rather than ScheduledTrigger.create!, because the
    # row is only half of it - add_job is what puts a runner on the clock.
    #
    # `auth: :buddy` with the person's own id is the on-behalf-of trail. Each
    # listening task still runs as ITS OWN owner, exactly as it would if the
    # trigger came from anywhere else, which is why nothing here needs to check
    # whether Buddy can reach the thing that's listening.
    schedule = ::Jil::Schedule.add_schedule(
      ctx.user,
      Time.zone.parse(payload[:fire_at_iso].to_s),
      payload[:scope].to_s,
      (payload[:trigger_data] || {}).transform_keys(&:to_s),
      auth:      :buddy,
      auth_id:   ctx.user.id,
      condition: payload[:condition],
    )
    raise "couldn't schedule that trigger" if schedule.nil?

    {
      scheduled_id: schedule.id,
      scope:        schedule.trigger,
      fire_at:      schedule.execute_at.iso8601,
      condition:    ScheduleCondition.describe(schedule.condition),
    }.compact
  },
  receipt:     ->(result, ctx) {
    fire_at = (Time.zone.parse(result[:fire_at].to_s) rescue nil)
    line    = "#{ctx.buddy_name} will fire `#{result[:scope]}` #{ctx.friendly_future(fire_at)}"
    result[:condition].present? ? "#{line}, #{result[:condition]}" : line
  },
)
