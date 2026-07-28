Buddy::Tools.register(
  name:        :create_chore,
  description: <<~TXT,
    Create a NEW chore in the user's household. Use when the user wants a
    task they haven't been tracking yet to become a repeating (or one-off)
    chore. Do NOT use to just complete something they already did - that's
    `complete_chore`.
  TXT
  args: {
    name:     { type: :string, required: true,  description: "Chore name" },
    schedule: { type: :string, required: false, description: "Free-form schedule text; blank means one-off" },
    assignee: { type: :string, required: false, description: "Household member first name, or 'me'" },
    one_off:  { type: :string, required: false, description: "Pass 'true' for a one-off chore" },
  },
  confirm: ->(payload, ctx) {
    assignee = payload[:assignee].present? ? ctx.resolve_household_user(payload[:assignee]) : ctx.user
    { summary: "Add new chore: #{payload[:name]}?", resolved: { assigned_to_user_id: assignee&.id } }
  },
  label: ->(payload, ctx) {
    subs = []
    subs << payload[:schedule].to_s if payload[:schedule].present?
    if payload[:assigned_to_user_id].present? && payload[:assigned_to_user_id] != ctx.user.id
      subs << "for #{User.find_by(id: payload[:assigned_to_user_id])&.first_name}"
    end
    { title: payload[:name].to_s, sub: subs.join("\n").presence }
  },
  execute: ->(payload, ctx) {
    household = ctx.user.chore_household
    raise "no chore household on user" if household.nil?

    chore = Chore.new(
      chore_household:     household,
      created_by_user:     ctx.user,
      name:                payload[:name],
      assigned_to_user_id: payload[:assigned_to_user_id],
      one_off:             payload[:one_off].to_s == "true",
    )
    if payload[:schedule].present? && chore.respond_to?(:schedule_text=)
      chore.schedule_text = payload[:schedule]
    end
    chore.save!
    { chore_id: chore.id }
  },
  receipt: ->(result, _ctx) {
    chore = Chore.find_by(id: result[:chore_id])
    "Created #{chore&.name || 'chore'} ✓"
  },
)
