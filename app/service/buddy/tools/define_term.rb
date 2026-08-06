Buddy::Tools.register(
  name:        :define_term,
  description: <<~TXT,
    Teach the household glossary a word. Use it when they explain what something
    means ("muti is medicine", "when I say the plunge I mean the trailhead in
    Alpine", "bakkie is a tub, not a truck"), or when you had to ask what a word
    meant and they told you. Once it's in, every companion in the house
    understands it and nobody has to explain it again.

    This is for VOCABULARY - a word and what it points at. A fact about the
    person ("she hates cilantro") is `remember` instead. Something to do is a
    chore, an agenda item, or `stash_idea`.

    `aliases` are the other ways they say the same thing, comma-separated
    ("puppy, the dog"). `notes` is for anything the meaning alone doesn't carry,
    most usefully when the term is a record name that shouldn't be spoken back
    in prose. Defining a term that already exists updates it rather than making
    a second one.
  TXT
  args:        {
    term:    { type: :string, required: true,  description: "The word or phrase, as they say it" },
    meaning: { type: :string, required: true,  description: "What it means, in one plain sentence" },
    aliases: { type: :string, required: false, description: "Other ways they say it, comma-separated" },
    kind:    {
      type:        :enum,
      required:    false,
      values:      %i[person pet place thing activity device shorthand],
      description: "What sort of thing it points at",
    },
    notes:   { type: :string, required: false, description: "Anything the meaning alone doesn't carry" },
  },
  confirm:     ->(payload, ctx) {
    term = payload[:term].to_s.strip
    raise "no word to define" if term.empty?
    raise "no meaning to give it" if payload[:meaning].to_s.strip.empty?

    household = ctx.user.chore_household
    raise "you're not in a household, so there's no glossary to add to" if household.nil?

    existing = HouseholdGlossaryTerm.where(chore_household_id: household.id)
      .where("LOWER(term) = ?", term.downcase).first

    {
      summary:  existing ? "Update **#{existing.term}**?" : "Teach the house **#{term}**?",
      resolved: { term: term, household_id: household.id, existing_id: existing&.id },
    }
  },
  label:       ->(payload, _ctx) {
    { title: "📖 #{payload[:term]} = #{payload[:meaning]}", sub: payload[:aliases].presence }
  },
  # One word is one entry, so saying it twice in a turn is one row.
  merge_key:   ->(payload) { "define_term:#{payload[:term].to_s.downcase.strip}" },
  supersedes:  true,
  # Level 2: known the moment it's said, as a pre-checked row that doubles as
  # the read-back. Unchecking means "no, that's not what it means".
  level:       2,
  # A definition is one particular word; replaying it inside a routine would
  # just re-teach the same thing.
  routinable:  false,
  execute:     ->(payload, _ctx) {
    aliases = payload[:aliases].to_s.split(",").map(&:strip).compact_blank
    attrs   = {
      meaning: payload[:meaning].to_s.strip,
      aliases: aliases,
      kind:    (payload[:kind].to_s if HouseholdGlossaryTerm.kinds.key?(payload[:kind].to_s)),
      notes:   payload[:notes].presence,
    }

    if payload[:existing_id].present? &&
       (row = HouseholdGlossaryTerm.find_by(id: payload[:existing_id]))
      before = row.slice(:meaning, :aliases, :kind, :notes)
      # An update that only adds aliases shouldn't drop the ones already there —
      # "oh, and I call it X too" is additive, not a replacement.
      attrs[:aliases] = (Array(row.aliases) + aliases).uniq if aliases.any?
      attrs[:kind] ||= row.kind
      attrs[:notes] ||= row.notes
      row.update!(attrs)
      return {
        term:   row.term,
        verb:   "Updated",
        revert: {
          op:      "updated",
          model:   "HouseholdGlossaryTerm",
          id:      row.id,
          before:  before,
          summary: "put #{row.term} back the way it was",
        },
      }
    end

    row = HouseholdGlossaryTerm.create!(attrs.merge(
                                          chore_household_id: payload[:household_id],
                                          term:               payload[:term].to_s.strip,
    ))
    {
      term:   row.term,
      verb:   "Learned",
      revert: { op: "created", model: "HouseholdGlossaryTerm", id: row.id, summary: "unlearn #{row.term}" },
    }
  },
  receipt:     ->(result, _ctx) { "#{result[:verb]} **#{result[:term]}** ✓" },
)
