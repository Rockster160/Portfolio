Buddy::Tools.register(
  name:        :ask_partner_choice,
  description: <<~TXT,
    Ask the user's partner (or a household member) a PICK-ONE question through
    their companion. Use for "ask if they'd rather do dishes or mop",
    "ask them: pizza, tacos, or thai?". Their companion shows the options as
    tappable buttons; tapping one sends that choice back to you.

    `to` is who to ask. `question` is the prompt, and it is READ BY them, so
    "you" means THEM and your own person gets named: "ask if he'll learn
    mahjong with me" goes out as "Will you learn mahjong with Chelsea?" - never
    "with you", which asks him to do it with himself. `options` is a
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

    What comes after the wait runs on ANY pick, because it was decided before
    they made one. So when the follow-up depends on WHICH they choose, add
    `continue_if`: the steps behind this one then run only when their pick
    matches it. Name the option - `continue_if: "dishes"` - or use "yes"/"no"
    when that's what the two options are. On any other pick the rest is dropped
    and your person is told what didn't happen.

    ## What YOU say back

    That you've asked, in one short line - "asked him, I'll let you know". The
    card goes out on its own and leaves its own receipt, so that's all that's
    left to say.

    NEVER answer the question yourself. "Ask Rocco if he can change the logo on
    the lights app to a simple house logo" came back as the single word "yes"
    (prod 3459-3460) - which reads as his answer, arrived instantly, and it was
    nothing of the kind. The whole point of relaying a question is that the
    reply comes from the person it was put to.
  TXT
  feature:     :relay,
  args:        {
    to:          { type: :string,  required: true,  description: "First name of anyone on the household roster in \"Who else is in the house\" - not only a partner" },
    question:    { type: :string,  required: true,  description: "The question, addressed TO them - \"you\" is the person being asked, and your own person is named" },
    options:     { type: :string,  required: true,  description: "Comma-separated choices, e.g. \"dishes, mop\"" },
    await_reply: { type: :boolean, required: false, description: "Hold the rest of the sequence until they pick. Only when a later step needs it." },
    var:         { type: :string,  required: false, description: "Name their pick is filed under, for a later {{step}} to use. With await_reply." },
    continue_if: { type: :string,  required: false, description: "Run the steps behind this one ONLY if their pick matches - name the option, or \"yes\"/\"no\". With await_reply. Leave it off when the follow-up should happen either way." },
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
    {
      relay_id:    relay.id,
      to_name:     payload[:to_name],
      var:         payload[:await_var],
      continue_if: Buddy::AnswerCondition.build(
        var: payload[:await_var], is: payload[:continue_if], who: payload[:to_name],
      ),
    }.compact
  },
  auto:        true,
  receipt:     ->(result, _ctx) {
    return "Asked #{result[:to_name]} — I'll pick this back up when they answer 💬" if result[:var]

    "Asked #{result[:to_name]} — I'll let you know what they pick 💬"
  },
)
