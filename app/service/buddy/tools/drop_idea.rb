Buddy::Tools.register(
  name:        :drop_idea,
  description: <<~TXT,
    Forget / drop a stashed brain-dump idea. Use when the person says to forget
    it, drop it, or never mind about one of their `stashed_ideas`. `id` is the
    idea's id.
  TXT
  args:        {
    id: { type: :integer, required: true, description: "Idea id from stashed_ideas" },
  },
  level:       1,
  # See move_idea: an idea id doesn't survive being replayed.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    idea = ctx.user.buddy_memories.kind_stash.live.find_by(id: payload[:id])
    raise "no stashed idea ##{payload[:id]}" if idea.nil?

    { summary: "Drop this idea?", resolved: {} }
  },
  label:       ->(_payload, _ctx) { { title: "Forget this idea", sub: nil } },
  execute:     ->(payload, ctx) {
    idea = ctx.user.buddy_memories.kind_stash.find(payload[:id])
    idea.update!(status: :dropped)
    { idea_id: idea.id }
  },
  receipt:     ->(_result, _ctx) { "Dropped it ✓" },
)
