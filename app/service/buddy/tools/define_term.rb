Buddy::Tools.register(
  name:        :define_term,
  description: <<~TXT,
    Teach the household glossary a word. Use it when they explain what something
    means ("muti is medicine", "when I say the plunge I mean the trailhead in
    Alpine", "bakkie is a tub, not a truck"), or when you had to ask what a word
    meant and they told you. The glossary is shared by the house, so the other
    companions get the word too.

    That last part is a fact about the plumbing, not a line to say back. Somebody
    teaching you their word wants YOU to have it; "tucked in for everyone, so
    nobody has to puzzle over it again" answers a question nobody asked, and it
    turns a bit of family shorthand into a comprehension problem that needed
    solving. Say it the way you'd say it to a friend who just let you in on
    something - the receipt already shows it was kept.

    This is for VOCABULARY - a word and what it points at. A fact about the
    person ("she hates cilantro") is `remember` instead. Something to do is a
    chore, an agenda item, or `stash_idea`.

    `aliases` are the other ways they say the same thing, comma-separated
    ("puppy, the dog"). `notes` is for anything the meaning alone doesn't carry,
    most usefully when the term is a record name that shouldn't be spoken back
    in prose. Defining a term that already exists updates it rather than making
    a second one.

    **CALLING THIS IS THE THANK-YOU.** Somebody teaching you a word wants it
    kept, and warm words about keeping it are not keeping it. "That one's going
    in the little bird pile" over no call at all is the worst answer available:
    it reads exactly like the real thing, so nobody finds out until they use the
    word again and you don't know it. If you say a word has been tucked away,
    this call is what made that true. Prod: Eve taught four Afrikaans phrases in
    ninety seconds, was told twice they were being kept, and one of them was
    never written anywhere.

    CHECK THE GLOSSARY FIRST. It's already in your context. A word that's in
    there is one they taught you before, and the honest answer is that you have
    it - not a fresh thank-you for a fresh gift, which tells them their last
    lesson went nowhere. Re-teaching with a changed meaning is a real update and
    should still be called.

    **AGREEING IS NOT TEACHING.** "You got it!", "yep, that's it", a thumbs up -
    those close the subject, they don't reopen it. Prod: `dealeo` was learned,
    refined fifty seconds later when she described the sing-song, and then
    written a THIRD time on a bare "You got it!" - same meaning, same aliases,
    nothing changed - which put a third card up and a third thank-you under it.
    Once a word is in and right, the next warm thing said about it is words, not
    a call.
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
      # "oh, and I call it X too" is additive, not a replacement. Unconditional
      # on purpose: guarded by `if aliases.any?` this left `attrs[:aliases]` as
      # the empty array it starts as, so any re-teaching that didn't happen to
      # mention them wiped the ones already held.
      attrs[:aliases] = (Array(row.aliases) + aliases).uniq
      attrs[:kind] ||= row.kind
      attrs[:notes] ||= row.notes

      # Re-teaching a word that already says exactly this is not an update, and
      # writing it as one is what turns "you got it!" into a third card and a
      # third thank-you for the same gift. Nothing changed, so there is nothing
      # to revert either.
      held = { meaning: row.meaning, aliases: Array(row.aliases), kind: row.kind, notes: row.notes }
      return { term: row.term, verb: "Already knew", held: true } if held == attrs

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
