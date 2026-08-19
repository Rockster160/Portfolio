Buddy::Tools.register(
  name:        :read_idea,
  description: <<~TXT,
    Open one held thought in full - the seed they started with and every note
    added since, oldest first, each stamped with how long ago it landed. The
    whole thing comes straight back to you in this turn.

    This is the "yeah, I remember the shape of this" call. Use it when they come
    back to something after a while and you need the actual thread rather than
    the one-line label: "remind me where I got to on the greenhouse", "what did
    I decide about that?", "read me back the slime colony stuff" - and also
    before you help them think one through, so you're building on what's there
    instead of starting the conversation over.

    `id` comes from "Things you're holding" or from search_ideas.

    What comes back is a transcript, not a script. Don't recite it at them.
    Use it to pick the thread back up in your own words, and say what's actually
    in there rather than a summary of a summary.
  TXT
  args:        {
    id: { type: :integer, required: true, description: "The held idea's number" },
  },
  auto:        true,
  answers:     true,
  confirm:     ->(_payload, _ctx) { { summary: "Read a held idea", resolved: {} } },
  label:       ->(_payload, _ctx) { "Read a held idea" },
  execute:     ->(payload, ctx) {
    idea = ctx.user.buddy_memories.kind_stash.includes(:notes).find_by(id: payload[:id])
    return { found: false, how: "There's no held idea ##{payload[:id]}. Say so plainly; don't invent one." } if idea.nil?

    count = idea.notes.size
    {
      found:      true,
      id:         idea.id,
      label:      idea.summary.presence,
      bucket:     idea.category_label,
      # `state`, not `status`: Turn.answer_output builds its reply as
      # `{ status: :answered }.merge(whatever this returns)`, so a `status` key
      # here silently overwrites the flag the model reads to know the lookup
      # succeeded — and "active" is a perfectly plausible-looking value to
      # overwrite it with.
      state:      idea.status,
      held_for:   idea.waiting_label,
      note_count: count,
      thread:     idea.transcript,
      how:        (
        if count.zero?
          "Nothing has been added to this one since they said it — the seed is the whole thing. Don't imply " \
            "there's more history than there is."
        else
          "`[seed]` is what started it and each `[...]` below is something added later, oldest first. A note " \
            "marked `[you, ...]` is YOURS, not theirs — never read one back as something they said. Pick the " \
            "thread up in your own words; if this conversation adds to it, that's `elaborate_idea`."
        end
      ),
    }.compact
  },
)
