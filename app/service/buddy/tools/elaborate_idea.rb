Buddy::Tools.register(
  name:        :elaborate_idea,
  description: <<~TXT,
    Add to something you're already holding, instead of starting a second pile
    for the same thought. Use it whenever they come back to an idea that's
    already in "Things you're holding" - "oh, about that greenhouse thing, I was
    also thinking...", "add to that: it should probably be solar", or any time
    they're clearly building on a thought rather than having a new one.

    `id` is the idea's number from "Things you're holding" or from
    search_ideas. `note` is what they added, close to their own words. Notes
    stack up oldest-first and none of them ever overwrite anything, so a thought
    can be returned to as many times as they like and the whole shape of it
    stays readable later.

    Two related calls that are NOT this one: a genuinely new thought is
    `stash_idea`, and a sharper one-line LABEL for the whole thread is the
    silent `[[stash: id=N summary="..."]]` marker rather than a note.

    Set `mine: true` for a note in YOUR voice - a shape you noticed, a summary
    of where the conversation got to. Those are kept separately so they're never
    read back later as something they said.
  TXT
  args:        {
    id:   { type: :integer, required: true,  description: "The held idea's number" },
    note: { type: :string,  required: true,  description: "What they've added, in their words" },
    mine: { type: :boolean, required: false, default: false, description: "True if this note is yours, not theirs" },
  },
  confirm:     ->(payload, ctx) {
    note = payload[:note].to_s.strip
    raise "nothing to add" if note.empty?

    idea = ctx.user.buddy_ideas.find_by(id: payload[:id])
    raise "no held idea ##{payload[:id]}" if idea.nil?

    {
      summary:  "Add to **#{idea.summary.presence || idea.body.to_s.truncate(60)}**?",
      resolved: { idea_id: idea.id, note: note, label: idea.summary.presence || idea.body.to_s.truncate(60) },
    }
  },
  label:       ->(payload, _ctx) {
    { title: "📝 #{payload[:note].to_s.truncate(80)}", sub: "adds to #{payload[:label]}" }
  },
  # The same addition said twice in one turn is one addition.
  merge_key:   ->(payload) { "elaborate_idea:#{payload[:id]}:#{payload[:note].to_s.downcase.strip}" },
  # Level 2: kept the moment it's said, as a pre-checked row that doubles as the
  # read-back. Unchecking removes the note and leaves the thread as it was.
  level:       2,
  # The value is the wording of one particular addition to one particular
  # thought; replaying it weeks later inside a routine is meaningless.
  routinable:  false,
  execute:     ->(payload, ctx) {
    idea = ctx.user.buddy_ideas.find_by(id: payload[:idea_id])
    raise "that idea is gone" if idea.nil?

    # Coming back to something they'd given up on is them picking it back up.
    # Leaving it closed means the note lands somewhere they'll never see it.
    idea.update!(status: :active) if idea.status_done? || idea.status_dropped?

    note = idea.notes.create!(
      body:   payload[:note].to_s.strip,
      source: ActiveModel::Type::Boolean.new.cast(payload[:mine]) ? :companion : :person,
    )
    {
      idea_id: idea.id,
      label:   idea.summary.presence || idea.body.to_s.truncate(60),
      count:   idea.notes.count,
      revert:  { op: "created", model: "BuddyIdeaNote", id: note.id, summary: "took that addition back off" },
    }
  },
  receipt:     ->(result, _ctx) {
    "Added to **#{result[:label]}** — #{result[:count]} #{"note".pluralize(result[:count])} now ✓"
  },
)
