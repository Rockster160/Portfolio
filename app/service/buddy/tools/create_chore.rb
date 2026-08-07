Buddy::Tools.register(
  name:        :create_chore,
  description: <<~TXT,
    Create a NEW chore in the user's household. Use when the user wants a task
    they haven't been tracking yet to become a repeating (or one-off) chore.
    Do NOT use to just complete something they already did - that's
    `complete_chore`.

    Optional details, only pass the ones the user actually gives:
      schedule - free-form recurrence: "every Sunday", "weekdays", "daily",
                 "every 3 days", "monthly on the 1st". Blank = one-off.
      assignee - a household member's first name, or "me".
      reward   - pebble reward (a number). If omitted, a sensible amount is
                 guessed from the chore; you don't need to ask.
      parent   - another chore name to nest this UNDER as a sub-task.
      after    - another chore name this one should follow (surfaces once that
                 chore is done) - a dependency, not a clock schedule.
      due      - when it should first be due ("today", "tomorrow", a date).
      priority - how urgent: critical / high / normal / low / none. Only pass
                 it when the user says so ("this one's urgent", "low priority",
                 "don't bother flagging it") - otherwise it defaults to normal.
    An icon is chosen automatically from the name.
  TXT
  feature:     :chores,
  args:        {
    name:     { type: :string, required: true,  description: "Chore name" },
    schedule: { type: :string, required: false, description: "Free-form schedule; blank = one-off" },
    assignee: { type: :string, required: false, description: "Household member first name, or 'me'" },
    reward:   { type: :integer, required: false, description: "Pebble reward; omit to auto-guess" },
    parent:   { type: :string, required: false, description: "Parent chore name to nest this under" },
    after:    { type: :string, required: false, description: "Chore this one follows (dependency)" },
    due:      { type: :string, required: false, description: "When it's first due - YYYY-MM-DD (from the local date in RIGHT NOW) or an ISO datetime" },
    one_off:  { type: :string, required: false, description: "Pass 'true' for a one-off chore" },
    priority: { type: :string, required: false, description: "Urgency: critical, high, normal, low, or none. Omit for normal" },
  },
  confirm:     ->(payload, ctx) {
    household = ctx.user.chore_household
    raise "no chore household on user" if household.nil?

    assignee = payload[:assignee].present? ? ctx.resolve_household_user(payload[:assignee]) : ctx.user

    # A named `after` chore is a dependency (after_chore recurrence); it takes
    # precedence over a clock schedule. Otherwise parse the free-form schedule.
    anchor = payload[:after].present? ? ctx.resolve_chore(payload[:after]) : nil
    raise "no chore matching #{payload[:after].inspect} to follow" if payload[:after].present? && anchor.nil?

    recurrence = if anchor
      { "freq" => "after_chore", "anchor_chore_id" => anchor.id, "interval" => 0, "unit" => "day" }
    else
      Buddy::ChoreScheduleParser.parse(payload[:schedule], on: ctx.user.perceived_today)
    end

    parent = payload[:parent].present? ? ctx.resolve_chore(payload[:parent]) : nil
    raise "no parent chore matching #{payload[:parent].inspect}" if payload[:parent].present? && parent.nil?

    reward = payload[:reward].present? ? payload[:reward].to_i : Buddy::PebbleGuide.guess(payload[:name])

    priority = Chore.priority_key(payload[:priority]) if payload[:priority].present?
    if payload[:priority].present? && priority.nil?
      raise "unknown priority #{payload[:priority].inspect} — use critical, high, normal, low, or none"
    end

    # Never leave the icon blank — fall back to a neutral checklist glyph when
    # the name doesn't score a confident match.
    icon = IconPool.best_match_value(payload[:name], for_household: household).presence || "📋"

    # Through resolve_due, not Time.zone.parse: a bare date parsed in the
    # app-wide UTC zone is the previous evening locally, and the chore day runs
    # 4am to 4am, so either way the chore came out due a day early.
    due_at = ctx.resolve_due(payload[:due]) if payload[:due].present?
    due_at = nil if due_at == :clear

    # Default it to TODAY. `marked_due_at` is the "appears on Today" stamp (see
    # ChoreSerializer#today_visible?), and a chore created without one lands
    # nowhere anybody looks: not on the Today tab, not in Buddy's pending list.
    # "Add calibrating the printer as a 5p chore" got a cheerful "it's on
    # there", and it wasn't on anything.
    #
    # A SCHEDULE is the user saying otherwise, so a recurring chore is left
    # alone — the stamp overrides the schedule for Today, and "mow the lawn
    # every Sunday" asked for on a Wednesday must not demand mowing today.
    due_at ||= ChoreDay.starts_at(ChoreDay.current(ctx.user), ctx.user) if recurrence.blank?

    {
      summary:  "Add new chore: #{payload[:name]}?",
      resolved: {
        assigned_to_user_id: assignee&.id,
        recurrence:          recurrence,
        reward_pebbles:      reward,
        priority:            priority,
        icon:                icon,
        parent_chore_id:     parent&.id,
        marked_due_at_iso:   due_at&.iso8601,
        schedule_human:      (anchor ? "after #{anchor.name}" : payload[:schedule].presence),
      }.compact,
    }
  },
  label:       ->(payload, ctx) {
    subs = []
    subs << payload[:schedule_human] if payload[:schedule_human].present?
    if payload[:parent_chore_id].present?
      subs << "under #{Chore.find_by(id: payload[:parent_chore_id])&.name}"
    end
    if payload[:assigned_to_user_id].present? && payload[:assigned_to_user_id] != ctx.user.id
      subs << "for #{User.find_by(id: payload[:assigned_to_user_id])&.first_name}"
    end
    subs << "#{payload[:priority]} priority" if payload[:priority].present?
    subs << "#{payload[:reward_pebbles]}p" if payload[:reward_pebbles].present?
    if payload[:marked_due_at_iso].present?
      subs << "due #{ctx.friendly_future(Time.zone.parse(payload[:marked_due_at_iso].to_s))}"
    end
    { title: payload[:name].to_s, sub: subs.join(" · ").presence }
  },
  # Level 2: the chore exists the moment it's proposed, as a pre-checked row
  # that unticks back off. They'd already said they wanted it, and a chore is
  # visible and reversible, so a confirmation tap was a toll on the common case.
  level:       2,
  execute:     ->(payload, ctx) {
    household = ctx.user.chore_household
    raise "no chore household on user" if household.nil?

    # Build through the household association with created_by_user set — the
    # same path ChoresController#create uses — so every model callback fires:
    # the Jil :chore created trigger, the Monitor broadcast, sub-chore + anchor
    # validation, default household backfill. (The old bare Chore.new skipped
    # icon/reward/recurrence entirely and called a nonexistent schedule_text=.)
    chore = household.chores.create!(
      created_by_user:     ctx.user,
      name:                payload[:name],
      assigned_to_user_id: payload[:assigned_to_user_id],
      one_off:             payload[:one_off].to_s == "true",
      reward_pebbles:      payload[:reward_pebbles],
      icon:                payload[:icon],
      # `.compact` in confirm drops the key entirely when the person
      # didn't say, so the column default (:normal) stands.
      priority:            payload[:priority] || :normal,
      recurrence:          payload[:recurrence],
      parent_chore_id:     payload[:parent_chore_id],
      marked_due_at:       (Time.zone.parse(payload[:marked_due_at_iso].to_s) if payload[:marked_due_at_iso].present?),
    )
    {
      chore_id: chore.id,
      # Unticking the row archives it — see Buddy::Reverter. Not a destroy: a
      # chore owns its completion history, and undoing "you just made this"
      # mustn't take that with it.
      revert:   { op: "created", model: "Chore", id: chore.id, summary: "removed #{chore.name}" },
    }
  },
  receipt:     ->(result, _ctx) {
    chore = Chore.find_by(id: result[:chore_id])
    "Created #{chore&.name || "chore"} ✓"
  },
)
