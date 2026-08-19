Buddy::Tools.register(
  name:        :move_idea,
  description: <<~TXT,
    Refile a stashed brain-dump idea into a different bucket. Use when the
    person says to move one of their stashed ideas (from `stashed_ideas` in the
    context file) to me / home / work. `id` is the idea's id; `category` is the
    new bucket.
  TXT
  args:        {
    id:       { type: :integer, required: true, description: "Idea id from stashed_ideas" },
    category: { type: :enum, required: true, values: %i[me home work], description: "New bucket" },
  },
  level:       1,
  # `id` names one stashed idea, so a saved copy points at whatever that id
  # happens to be months later.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    idea = ctx.user.buddy_memories.kind_stash.live.find_by(id: payload[:id])
    raise "no stashed idea ##{payload[:id]}" if idea.nil?

    { summary: "Move idea to #{payload[:category]}?", resolved: {} }
  },
  label:       ->(payload, _ctx) { { title: "Move idea → #{payload[:category]}", sub: nil } },
  execute:     ->(payload, ctx) {
    idea = ctx.user.buddy_memories.kind_stash.find(payload[:id])
    idea.update!(category: payload[:category].to_s, status: :active)
    { idea_id: idea.id, category: payload[:category].to_s }
  },
  receipt:     ->(result, _ctx) { "Moved it to #{BuddyMemory::CATEGORY_LABELS[result[:category]]} ✓" },
)
