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

    Either way it is READ BY the person being asked, so "you" means THEM. Your
    own person gets named: "ask if he'll come with me" goes out as "Will you
    come with Chelsea?", never "with you".

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

    What comes after the wait runs on ANY answer unless you say otherwise, so
    when the follow-up depends on WHAT they say, add `continue_if`. "Ask Chelsea
    if she wants syrup for dinner, and if she says yes put it on the agenda" is
    `continue_if: "yes"`: the steps behind it run on a yes, and on a no they are
    dropped and your person is told what didn't happen. Name the answer itself
    when it isn't a yes/no - `continue_if: "pizza"`. An answer that's neither
    one thing nor the other stops it too, and says so.

    Without `continue_if` the dinner goes on the agenda whether she wanted it or
    not, so put one on every "if they say" sequence.

    ## What YOU say back

    That you've asked, in one short line - "asked her, I'll pass on what she
    says". This tool sends the question and leaves its own receipt, so that's
    all that's left to say.

    Never answer the question yourself and never read it back. A reply that
    does either reads as the answer having already come in, when nobody has
    even been asked yet.
  TXT
  feature:     :relay,
  args:        {
    to:          { type: :string,  required: true,  description: "First name of anyone on the household roster in \"Who else is in the house\" - not only a partner" },
    question:    { type: :string,  required: true,  description: "What to ask, addressed TO them - \"you\" is the person being asked, and your own person is named. Their exact words when they gave you words." },
    await_reply: { type: :boolean, required: false, description: "Hold the rest of the sequence until they answer. Only when a later step needs what they say." },
    var:         { type: :string,  required: false, description: "Name their answer is filed under, for a later {{step}} to use. With await_reply." },
    continue_if: { type: :string,  required: false, description: "Run the steps behind this one ONLY if their answer matches - \"yes\", \"no\", or the answer by name. With await_reply. Leave it off when the follow-up should happen either way." },
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
    # answer has to land somewhere named for the step behind it to reach. The
    # condition rides with it for the same reason: the gate is where it has to
    # be sitting when the reply finally lands.
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

    "Asked #{result[:to_name]} — I'll let you know what they say 💬"
  },
)
