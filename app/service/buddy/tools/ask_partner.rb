Buddy::Tools.register(
  name:        :ask_partner,
  description: <<~TXT,
    Ask the user's partner (or a household member) an OPEN-ENDED question
    through their companion, and bring back whatever they say. Use for "ask
    Chelsea what she wants for dinner", "find out when Rocco's getting home",
    "ask her how she's feeling". Their companion asks in its own voice, waits
    for a natural reply, and passes the answer back to you.

    `to` is who to ask (household member). `question` is what you want to know,
    phrased as intent. For a pick-ONE question use ask_partner_choice; for a
    pick-ANY / select-all question use ask_partner_multi.
  TXT
  args:        {
    to:       { type: :string, required: true, description: "Who to ask (household member)" },
    question: { type: :string, required: true, description: "What to ask, phrased as intent" },
  },
  confirm:     ->(payload, ctx) {
    partner = ctx.resolve_household_user(payload[:to])
    raise "I'm not sure who #{payload[:to]} is" if partner.nil? || partner == ctx.user

    { summary: "Ask #{partner.first_name}: #{payload[:question]}", resolved: { to_user_id: partner.id, to_name: partner.first_name } }
  },
  label:       ->(payload, _ctx) { { title: "Ask #{payload[:to_name]}", sub: payload[:question].to_s } },
  execute:     ->(payload, ctx) {
    relay = BuddyRelay.create!(
      from_user:         ctx.user,
      to_user_id:        payload[:to_user_id],
      from_conversation: ctx.conversation,
      kind:              :ask_open,
      body:              payload[:question].to_s,
      status:            :pending,
    )
    Buddy::CompanionRelay.deliver!(relay)
    { relay_id: relay.id, to_name: payload[:to_name] }
  },
  auto:        true,
  receipt:     ->(result, _ctx) { "Asked #{result[:to_name]} — I'll let you know what they say 💬" },
)
