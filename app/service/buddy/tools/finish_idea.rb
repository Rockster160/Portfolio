Buddy::Tools.register(
  name:        :finish_idea,
  description: <<~TXT,
    Tick a held item off - they did the thing, or it resolved itself, so it
    stops coming back up. Use this when they report doing something you're
    holding for them ("called the dentist", "that's sorted", "already did the
    gate"), NOT when they want it forgotten unfinished - that's drop_idea.
    `id` is the item's id from the list of what you're holding.
  TXT
  args:        {
    id: { type: :integer, required: true, description: "Idea id from the things you're holding" },
  },
  # See move_idea: an idea id doesn't survive being replayed.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    idea = ctx.user.buddy_ideas.live.find_by(id: payload[:id])
    raise "no held item ##{payload[:id]}" if idea.nil?

    { summary: "Tick this off?", resolved: { label: idea.summary.presence || idea.body.to_s.first(60) } }
  },
  label:       ->(payload, _ctx) { { title: "✓ #{payload[:label]}", sub: nil } },
  # Level 2: ticked off on arrival, and unchecking puts it back in the pool -
  # a wrongly-closed loop is exactly the thing that goes missing otherwise.
  level:       2,
  execute:     ->(payload, ctx) {
    idea   = ctx.user.buddy_ideas.find(payload[:id])
    before = { "status" => idea.status, "remind_after" => idea.remind_after }
    idea.update!(status: :done, remind_after: nil)
    {
      idea_id: idea.id,
      label:   payload[:label],
      revert:  { op: "updated", model: "BuddyIdea", id: idea.id, before: before, summary: "put that back on your pile" },
    }
  },
  receipt:     ->(result, _ctx) { "Ticked off #{result[:label]} ✓" },
)
