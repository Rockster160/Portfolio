Buddy::Tools.register(
  name:        :ask_partner,
  description: <<~TXT,
    Ask the user's partner (or a household member) an OPEN-ENDED question
    through their companion, and bring back whatever they say. Use for "ask
    them what they want for dinner", "find out when they're getting home",
    "ask how they're feeling". Their companion asks in its own voice, waits
    for a natural reply, and passes the answer back to you.

    `to` is who to ask (household member). `question` is what you want to know.
    When they only gave you the gist ("ask what she wants for dinner"), the
    wording is yours. When they GAVE YOU THE WORDS - after "ask her:" or inside
    quotes - send those exactly, capitals and punctuation and all; how they
    phrased it is part of what they're asking.

    For a pick-ONE question use ask_partner_choice; for a pick-ANY /
    select-all question use ask_partner_multi.

    ## Waiting on the answer

    Normally this fires and the turn carries on - their reply arrives whenever
    it arrives. Set `await_reply: true` when a LATER STEP genuinely needs what
    they say: everything queued behind it is then held until they answer, and
    their answer is filed under `var` for a later step to reference as
    `{{that_name}}`.

      ask_partner(to: "Chelsea", question: "What do you want for dinner?",
                  await_reply: true, var: "hers")
      call_jil_function(name: "Dinner Planner", hers: "{{hers}}")

    Use it only when something really is downstream of the answer. A person is
    not a countdown: they may take hours, or never reply at all, and everything
    behind the wait sits there until they do.
  TXT
  feature:     :relay,
  args:        {
    to:          { type: :string,  required: true,  description: "First name of anyone on the household roster in \"Who else is in the house\" - not only a partner" },
    question:    { type: :string,  required: true,  description: "What to ask. Their exact words when they gave you words; your phrasing when they only gave you the gist." },
    await_reply: { type: :boolean, required: false, description: "Hold the rest of the sequence until they answer. Only when a later step needs what they say." },
    var:         { type: :string,  required: false, description: "Name their answer is filed under, for a later {{step}} to use. With await_reply." },
  },
  confirm:     ->(payload, ctx) {
    partner = ctx.resolve_household_user(payload[:to])
    raise "I'm not sure who #{payload[:to]} is" if partner.nil? || partner == ctx.user

    awaiting = Buddy::StepVars.awaiting?(payload)
    {
      summary:  "Ask #{partner.first_name}: #{payload[:question]}",
      resolved: {
        to_user_id: partner.id,
        to_name:    partner.first_name,
        # Resolved rather than re-derived in execute, so the "is anything
        # waiting on this" question is answered once, here, where it can raise
        # while the person is still in the conversation.
        await_var:  (Buddy::StepVars.capture_name!(payload, required: awaiting) if awaiting),
      }.compact,
    }
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
    # `var` rides back out so ProposalBuilder can key the gate to it — the
    # answer has to land somewhere named for the step behind it to reach.
    { relay_id: relay.id, to_name: payload[:to_name], var: payload[:await_var] }.compact
  },
  auto:        true,
  receipt:     ->(result, _ctx) {
    return "Asked #{result[:to_name]} — I'll pick this back up when they answer 💬" if result[:var]

    "Asked #{result[:to_name]} — I'll let you know what they say 💬"
  },
)
