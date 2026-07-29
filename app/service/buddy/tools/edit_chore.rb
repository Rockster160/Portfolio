Buddy::Tools.register(
  name:        :edit_chore,
  description: <<~TXT,
    Edit an existing chore. Use to rename, change the schedule, reassign,
    or archive/unarchive a chore the user already has. Only include the
    fields that are changing.
  TXT
  args:        {
    chore:    { type: :string, required: true,  description: "Fuzzy name of the chore to edit" },
    name:     { type: :string, required: false, description: "New name" },
    schedule: { type: :string, required: false, description: "New schedule text" },
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
    { summary: "Edit #{chore.name}?", resolved: { chore_id: chore.id, assignee_id: assignee_id, recurrence: recurrence } }
  },
  label:       ->(payload, _ctx) {
    chore = Chore.find_by(id: payload[:chore_id])
    base = chore&.name || payload[:chore].to_s
    diffs = []
    diffs << "name → #{payload[:name]}" if payload[:name].present?
    diffs << "schedule → #{payload[:schedule]}" if payload[:schedule].present?
    diffs << "assign → #{User.find_by(id: payload[:assignee_id])&.first_name}" if payload[:assignee_id]
    diffs << (payload[:disabled] == "true" ? "archive" : "unarchive") if payload.key?(:disabled)
    { title: base, sub: diffs.join("\n").presence }
  },
  execute:     ->(payload, _ctx) {
    chore = Chore.find(payload[:chore_id])
    attrs = {}
    attrs[:name]                = payload[:name]        if payload[:name].present?
    attrs[:assigned_to_user_id] = payload[:assignee_id] if payload[:assignee_id]
    attrs[:recurrence]          = payload[:recurrence]  if payload[:recurrence].present?
    if payload.key?(:disabled)
      attrs[:archived_at] = payload[:disabled] == "true" ? Time.current : nil
    end
    chore.update!(attrs) unless attrs.empty?
    { chore_id: chore.id, updated_fields: attrs.keys }
  },
  receipt:     ->(_result, ctx) {
    name = Chore.find_by(id: ctx.proposal["payload"]&.dig("chore_id"))&.name || "chore"
    "Updated #{name} ✓"
  },
)
