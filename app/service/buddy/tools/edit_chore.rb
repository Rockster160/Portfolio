Buddy::Tools.register(
  name:        :edit_chore,
  description: <<~TXT,
    Edit an existing chore. Use to rename, change the schedule, reassign, set
    when it's next due, change how urgent it is, or archive/unarchive a chore
    the user already has. Only include the fields that are changing.

    `priority` is urgency, not payout — it sorts the chore up the Today list,
    weights its odds of being picked as a Hot Pick, and flags the card when
    it's critical or high. "Bump the vet thing up", "that one's urgent now",
    "stop pushing the litter box at me" are all priority edits. The pebble
    reward is a separate thing; don't reach for one when they meant the other.

    `due` vs `schedule` — these are different things and mixing them up is the
    easy mistake. `schedule` is the RECURRENCE, how often it comes back ("every
    Sunday", "weekdays"). `due` is a ONE-OFF date for the next time only, and
    it leaves the recurrence alone: "the trash goes out Tuesday this week",
    "bump the vet thing to Friday", "this one's due tomorrow". Pass `due` as a
    date (YYYY-MM-DD) taken from the local date in RIGHT NOW, or a full ISO
    datetime when the hour genuinely matters. Pass "none" to clear it.
  TXT
  feature:     :chores,
  args:        {
    chore:    { type: :string, required: true,  description: "Fuzzy name of the chore to edit" },
    name:     { type: :string, required: false, description: "New name" },
    schedule: { type: :string, required: false, description: "New RECURRENCE, e.g. 'every Sunday'" },
    due:      { type: :string, required: false, description: "When it's next due - YYYY-MM-DD or ISO datetime, or 'none' to clear. A one-off, not the recurrence" },
    assignee: { type: :string, required: false, description: "New assignee (household member first name)" },
    priority: { type: :string, required: false, description: "New urgency: critical, high, normal, low, or none" },
    disabled: { type: :string, required: false, description: "'true' to archive, 'false' to unarchive" },
  },
  confirm:     ->(payload, ctx) {
    chore = ctx.resolve_chore(payload[:chore])
    raise ctx.no_chore_error(payload[:chore]) if chore.nil?

    # An edit with nothing to edit is a mistake worth catching here, the same
    # way update_delivery catches it. Left through, `execute` writes no
    # attributes, returns `updated_fields: []` and `before: {}`, and the receipt
    # still says "Updated Charge Villager Car ✓" over an undo row that undoes
    # nothing (prod byte_action 493). A phantom confirmation is worse than an
    # error, because the error is the thing that makes the model say what it
    # actually wants changed.
    given = payload.values_at(:name, :schedule, :due, :assignee, :priority, :disabled)
    if given.all? { |v| v.to_s.strip.blank? }
      raise "nothing to change on #{chore.name} - say what should be different"
    end

    assignee_id = payload[:assignee].present? ? ctx.resolve_household_user(payload[:assignee])&.id : nil
    # Parse the schedule to the real recurrence hash here (the old code assigned
    # a nonexistent `schedule_text=`, silently dropping every schedule edit).
    recurrence = Buddy::ChoreScheduleParser.parse(payload[:schedule], on: ctx.user.perceived_today) if payload[:schedule].present?

    # Resolved here rather than at execute so an unparseable date is caught
    # while the model can still say so, instead of silently not moving anything.
    due = ctx.resolve_due(payload[:due]) if payload[:due].present?
    raise "couldn't read #{payload[:due].inspect} as a due date" if payload[:due].present? && due.nil?

    # Same reason as the due date: resolved now so an unrecognized word
    # comes back as an error the model can act on, rather than an edit
    # that silently leaves the priority where it was.
    priority = Chore.priority_key(payload[:priority]) if payload[:priority].present?
    if payload[:priority].present? && priority.nil?
      raise "unknown priority #{payload[:priority].inspect} — use critical, high, normal, low, or none"
    end

    {
      summary:  "Edit #{chore.name}?",
      resolved: {
        chore_id:    chore.id,
        assignee_id: assignee_id,
        recurrence:  recurrence,
        priority:    priority,
        # "clear" is the unset-it sentinel; an absent key means "leave it".
        due_at_iso:  (due == :clear ? "clear" : due&.iso8601),
      },
    }
  },
  label:       ->(payload, ctx) {
    chore = Chore.find_by(id: payload[:chore_id])
    base = chore&.name || payload[:chore].to_s
    diffs = []
    diffs << "name → #{payload[:name]}" if payload[:name].present?
    diffs << "schedule → #{payload[:schedule]}" if payload[:schedule].present?
    if payload[:due_at_iso] == "clear"
      diffs << "no due date"
    elsif payload[:due_at_iso].present?
      diffs << "due #{ctx.friendly_future(Time.zone.parse(payload[:due_at_iso].to_s))}"
    end
    diffs << "priority → #{payload[:priority]}" if payload[:priority].present?
    diffs << "assign → #{User.find_by(id: payload[:assignee_id])&.first_name}" if payload[:assignee_id]
    diffs << (payload[:disabled] == "true" ? "archive" : "unarchive") if payload.key?(:disabled)
    { title: base, sub: diffs.join("\n").presence }
  },
  # Level 2: the edit lands as a pre-checked row that unticks back off, since
  # `before` below snapshots every field being written and Buddy::Reverter puts
  # them back exactly.
  level:       2,
  execute:     ->(payload, _ctx) {
    chore = Chore.find(payload[:chore_id])
    attrs = {}
    attrs[:name]                = payload[:name]        if payload[:name].present?
    attrs[:assigned_to_user_id] = payload[:assignee_id] if payload[:assignee_id]
    attrs[:recurrence]          = payload[:recurrence]  if payload[:recurrence].present?
    attrs[:priority]            = payload[:priority]    if payload[:priority].present?
    if payload[:due_at_iso].present?
      attrs[:marked_due_at] = (Time.zone.parse(payload[:due_at_iso].to_s) unless payload[:due_at_iso] == "clear")
    end
    if payload.key?(:disabled)
      attrs[:archived_at] = payload[:disabled] == "true" ? Time.current : nil
    end
    prior_name = chore.name
    before     = attrs.keys.index_with { |k| chore.public_send(k) }  # old values, for undo
    chore.update!(attrs) unless attrs.empty?
    {
      chore_id:       chore.id,
      updated_fields: attrs.keys,
      revert:         { op: "updated", model: "Chore", id: chore.id, before: before, summary: "reverted #{prior_name}" },
    }
  },
  receipt:     ->(_result, ctx) {
    name = Chore.find_by(id: ctx.proposal["payload"]&.dig("chore_id"))&.name || "chore"
    "Updated #{name} ✓"
  },
)
