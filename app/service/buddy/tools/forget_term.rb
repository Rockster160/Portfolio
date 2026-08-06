Buddy::Tools.register(
  name:        :forget_term,
  description: <<~TXT,
    Drop a word from the household glossary. Use when they say a word doesn't
    mean that any more, or that they never say it, or that it was wrong.

    To CHANGE what a word means, don't drop it first: define_term on the same
    word updates it in place.
  TXT
  args:        {
    term: { type: :string, required: true, description: "The word to drop - fuzzy, matched against the glossary" },
  },
  routinable:  false,
  confirm:     ->(payload, ctx) {
    household = ctx.user.chore_household
    raise "you're not in a household, so there's no glossary" if household.nil?

    row = HouseholdGlossaryTerm.lookup(household, payload[:term])
    raise "#{payload[:term].inspect} isn't in the glossary" if row.nil?

    { summary: "Drop **#{row.term}**?", resolved: { term_id: row.id, term: row.term, meaning: row.meaning } }
  },
  label:       ->(payload, _ctx) {
    { title: "Forget #{payload[:term]}", sub: payload[:meaning].presence }
  },
  execute:     ->(payload, ctx) {
    row = HouseholdGlossaryTerm.find_by(id: payload[:term_id], chore_household_id: ctx.user.chore_household_id)
    raise "that one's already gone" if row.nil?

    attrs = row.attributes.except("id", "created_at", "updated_at")
    name  = row.term
    row.destroy!
    {
      term:   name,
      revert: { op: "recreated", model: "HouseholdGlossaryTerm", attrs: attrs, summary: "put #{name} back" },
    }
  },
  receipt:     ->(result, _ctx) { "Dropped **#{result[:term]}** from the glossary ✓" },
)
