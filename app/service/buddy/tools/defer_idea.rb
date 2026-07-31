Buddy::Tools.register(
  name:        :defer_idea,
  description: <<~TXT,
    Push a stashed brain-dump idea off to bring up later. Use when the person
    says "not now, bring that one up later" about one of their `stashed_ideas`.
    `id` is the idea's id; optional `at` is an ISO time to resurface it (default
    a few days out).
  TXT
  args:        {
    id: { type: :integer, required: true,  description: "Idea id from stashed_ideas" },
    at: { type: :string,  required: false, description: "ISO time to bring it back up (optional)" },
  },
  level:       1,
  # See move_idea: an idea id doesn't survive being replayed.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    idea = ctx.user.buddy_ideas.live.find_by(id: payload[:id])
    raise "no stashed idea ##{payload[:id]}" if idea.nil?

    at = (Time.zone.parse(payload[:at].to_s) rescue nil) if payload[:at].present?
    { summary: "Bring this idea back later?", resolved: { remind_after_iso: (at || 3.days.from_now).iso8601 } }
  },
  label:       ->(_payload, _ctx) { { title: "Remind me about this idea later", sub: nil } },
  execute:     ->(payload, ctx) {
    idea = ctx.user.buddy_ideas.find(payload[:id])
    idea.update!(status: :deferred, remind_after: Time.zone.parse(payload[:remind_after_iso].to_s))
    { idea_id: idea.id }
  },
  receipt:     ->(_result, _ctx) { "I'll bring that back up later ✓" },
)
