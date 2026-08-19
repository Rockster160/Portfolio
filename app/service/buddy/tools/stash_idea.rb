Buddy::Tools.register(
  name:        :stash_idea,
  description: <<~TXT,
    Hold onto a THOUGHT that came up in passing so it can't get lost - an idea,
    a worry, a question to look into, a follow-up they'd be annoyed to have
    forgotten. The test is whether there's still thinking to do: "I keep meaning
    to sort out the greenhouse" is a thought, and so is "does the blueberry
    bush actually need phosphorus?".

    A JOB is not a thought and does not belong here. Anything they could simply
    go and do - an errand, a chore, a thing to fetch, check, put back or throw
    out - is `add_list_item` onto one of their lists. "Bring the meat
    thermometer out to the tomatoes", "chuck the old plastic pots", "put the
    metal decorations back up" are list items, every one. A pile of thoughts
    with a dozen errands mixed in is a pile nobody can read. Also not this: a
    clock time is an agenda item, and a nudge at a time or on a condition is
    `schedule_reminder` / `remind_when`.

    When someone is thinking out loud and several loose ends land in one
    message, that is several calls - one per thing, and they don't all have to
    be this tool. Keep `idea` close to their own words, but EACH ONE HAS TO
    STAND ALONE: the pile is not ordered and these are never read side by side,
    so "and after that, clear out the pantry" surfaces on its own, weeks later,
    pointing at nothing. Splitting their sentence is only half the job - carry
    enough of it into each piece that each piece still says something. `summary`
    is your own short label for it, and `category` files it under me (personal),
    home (household/family), or work. This CREATES a new held item - to file or
    relabel one that's already stashed, use sort_stash instead.
  TXT
  args:        {
    idea:     { type: :string, required: true,  description: "The thing to hold onto, in their words" },
    category: { type: :enum,   required: false, values: %i[me home work], description: "Which bucket it belongs in" },
    summary:  { type: :string, required: false, description: "Your own 3-6 word label for it" },
  },
  confirm:     ->(payload, _ctx) {
    idea = payload[:idea].to_s.strip
    raise "nothing to hold onto" if idea.empty?
    # The stash latch already refuses these; this is the other door into the
    # same pile, and a pile with "Thanks!" in it is worse than one thing
    # shorter because every later read has to step over it.
    raise "#{idea.inspect} is manners, not a thought - nothing to hold" if Buddy::Stash.pleasantry?(idea)

    { summary: "Hold onto #{idea}?", resolved: { idea: idea } }
  },
  label:       ->(payload, _ctx) {
    bucket = BuddyMemory::CATEGORY_LABELS[payload[:category].to_s]
    { title: "📥 #{payload[:summary].presence || payload[:idea]}", sub: bucket }
  },
  # Two dumps of the same thought in one turn is one thing to hold, not two.
  merge_key:   ->(payload) { "stash_idea:#{payload[:idea].to_s.downcase.strip}" },
  # "no, file that under work" is a correction of what was just caught, so the
  # first row retires rather than leaving two copies of one thought.
  supersedes:  true,
  # Level 2: held the moment it's said, as a pre-checked row. The row doubles as
  # the read-back of what was caught, and unchecking it means "that's not a
  # thing, let it go".
  level:       2,
  # The whole value is the wording of one particular thought, so replaying it
  # weeks later inside a routine would just re-stash a stale idea.
  routinable:  false,
  execute:     ->(payload, ctx) {
    body     = payload[:idea].to_s.strip
    category = (payload[:category].to_s if BuddyMemory.categories.key?(payload[:category].to_s))

    # Saying the same thing twice is one thing to hold, whether the two came in
    # the same breath or three days apart - and someone who talks to empty their
    # head circles the same loose end constantly. A second telling fills in
    # whatever the first one didn't carry rather than starting a second pile.
    held = ctx.user.buddy_memories.kind_stash.live.where("LOWER(content) = ?", body.downcase).first
    if held
      held.update!(category: held.category || category, summary: held.summary.presence || payload[:summary].presence)
      return { idea_id: held.id, label: held.summary.presence || held.content }
    end

    idea = ctx.user.buddy_memories.create!(
      kind:     :stash,
      content:  body,
      summary:  payload[:summary].presence,
      category: category,
      status:   :active,
    )
    {
      idea_id: idea.id,
      label:   idea.summary.presence || idea.content,
      revert:  { op: "created", model: "BuddyMemory", id: idea.id, summary: "let go of that one" },
    }
  },
  receipt:     ->(result, _ctx) { "Holding onto #{result[:label]} ✓" },
)
