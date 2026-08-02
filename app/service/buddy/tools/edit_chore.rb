Buddy::Tools.register(
  name:        :edit_chore,
  description: <<~TXT,
    Edit an existing chore. Use to rename, change the schedule, reassign, set
    when it's next due, or archive/unarchive a chore the user already has. Only
    include the fields that are changing.

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
    disabled: { type: :string, required: false, description: "'true' to archive, 'false' to unarchive" },
  },
  confirm:     ->(payload, ctx) {
    chore = ctx.resolve_chore(payload[:chore])
    raise "no chore matching #{payload[:chore].inspect}" if chore.nil?

    assignee_id = payload[:assignee].present? ? ctx.resolve_household_user(payload[:assignee])&.id : nil
    # Parse the schedule to the real recurrence hash here (the old code assigned
    # a nonexistent `schedule_text=`, silently dropping every schedule edit).
    recurrence = Buddy::ChoreScheduleParser.parse(payload[:schedule], on: ctx.user.perceived_today) if payload[:schedule].present?

    # Resolved here rather than at execute so an unparseable date is caught
    # while the model can still say so, instead of silently not moving anything.
    due = ctx.resolve_due(payload[:due]) if payload[:due].present?
    raise "couldn't read #{payload[:due].inspect} as a due date" if payload[:due].present? && due.nil?

    {
      summary:  "Edit #{chore.name}?",
      resolved: {
        chore_id:    chore.id,
        assignee_id: assignee_id,
        recurrence:  recurrence,
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
