Buddy::Tools.register(
  name:        :ask_partner_choice,
  description: <<~TXT,
    Ask the user's partner (or a household member) a PICK-ONE question through
    their companion. Use for "ask if they'd rather do dishes or mop",
    "ask them: pizza, tacos, or thai?". Their companion shows the options as
    tappable buttons; tapping one sends that choice back to you.

    `to` is who to ask. `question` is the prompt. `options` is a
    COMMA-SEPARATED list of the choices (at least two), e.g.
    options="dishes, mop". Do NOT use brackets or quotes inside the list.
    For a select-all / pick-any question, use ask_partner_multi instead.

    When a LATER STEP needs what they pick, add `await_reply: true` and a `var`:
    everything queued behind this holds until they tap one, and what they picked
    is filed under that name for a later step to use as `{{that_name}}`.

      ask_partner_choice(to: "Chelsea", question: "Dinner?", options: "tacos, curry",
                         await_reply: true, var: "hers")
      call_jil_function(name: "Dinner Planner", meal: "{{hers}}")

    Use it only when something really is downstream of the answer - a person is
    not a countdown, and anything behind the wait sits there until they reply.
  TXT
  feature:     :relay,
  args:        {
    to:          { type: :string,  required: true,  description: "First name of anyone on the household roster in \"Who else is in the house\" - not only a partner" },
    question:    { type: :string,  required: true,  description: "The question to pose" },
    options:     { type: :string,  required: true,  description: "Comma-separated choices, e.g. \"dishes, mop\"" },
    await_reply: { type: :boolean, required: false, description: "Hold the rest of the sequence until they pick. Only when a later step needs it." },
    var:         { type: :string,  required: false, description: "Name their pick is filed under, for a later {{step}} to use. With await_reply." },
  },
  confirm:     ->(payload, ctx) {
    partner = ctx.resolve_household_user(payload[:to])
    raise "I'm not sure who #{payload[:to]} is" if partner.nil? || partner == ctx.user

    options = payload[:options].to_s.split(",").map(&:strip).compact_blank
    raise "give me at least two options" if options.length < 2

    awaiting = Buddy::StepVars.awaiting?(payload)
    {
      summary:  "Ask #{partner.first_name}: #{payload[:question]}",
      resolved: {
        to_user_id: partner.id,
        to_name:    partner.first_name,
        options:    options,
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
      kind:              :ask_choice,
      body:              payload[:question].to_s,
      options:           Array(payload[:options]),
      status:            :pending,
    )
    Buddy::CompanionRelay.deliver!(relay)
    { relay_id: relay.id, to_name: payload[:to_name], var: payload[:await_var] }.compact
  },
  auto:        true,
  receipt:     ->(result, _ctx) {
    return "Asked #{result[:to_name]} — I'll pick this back up when they answer 💬" if result[:var]

    "Asked #{result[:to_name]} — I'll let you know what they pick 💬"
  },
)
