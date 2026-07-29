Buddy::Tools.register(
  name:        :message_partner,
  description: <<~TXT,
    Relay a message to the user's partner (or another household member)
    THROUGH their companion. Use whenever the user wants to tell / let / pass
    something along to someone else: "let Chelsea know I fed the dog", "tell
    Rocco I'm running late", "pass along that dinner's ready". The message is
    delivered VERBATIM as a bridged message from you, so phrase `message` as the
    actual, natural note you're sending (in your voice) - not a terse instruction.

    `to` is who it's for (a first name like "Chelsea", or "my wife"/"Rocco").
    It must be someone in the user's household - if you don't recognize the
    name, say you're not sure who they mean rather than guessing.

    This is one-way. If the user wants an ANSWER back, use ask_partner (open
    question), ask_partner_choice (pick one), or ask_partner_multi (pick any).
  TXT
  args:        {
    to:      { type: :string, required: true, description: "Who the message is for (household member)" },
    message: { type: :string, required: true, description: "What to pass along, phrased as intent" },
  },
  confirm:     ->(payload, ctx) {
    partner = ctx.resolve_household_user(payload[:to])
    raise "I'm not sure who #{payload[:to]} is" if partner.nil? || partner == ctx.user

    { summary: "Let #{partner.first_name} know: #{payload[:message]}", resolved: { to_user_id: partner.id, to_name: partner.first_name } }
  },
  label:       ->(payload, _ctx) { { title: "Message #{payload[:to_name]}", sub: payload[:message].to_s } },
  execute:     ->(payload, ctx) {
    relay = BuddyRelay.create!(
      from_user:         ctx.user,
      to_user_id:        payload[:to_user_id],
      from_conversation: ctx.conversation,
      kind:              :notify,
      body:              payload[:message].to_s,
      status:            :pending,
    )
    Buddy::CompanionRelay.deliver!(relay)
    { relay_id: relay.id, to_name: payload[:to_name] }
  },
  # Delivering to a partner is low-stakes and conversational, so it goes out
  # immediately and drops a receipt chip rather than a confirmation checkbox.
  auto:        true,
  receipt:     ->(result, _ctx) { "Passed it along to #{result[:to_name]} 💬" },
)
