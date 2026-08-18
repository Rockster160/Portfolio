Buddy::Tools.register(
  name:        :ask_partner_multi,
  description: <<~TXT,
    Ask the user's partner (or a household member) a SELECT-ALL / pick-any
    question through their companion. Use for "ask which love languages
    resonate: words, time, touch, service, gifts", "ask which of these
    chores they're up for tonight". Their companion shows the options as
    checkboxes with a Send button, so they can pick several at once;
    the full set comes back to you.

    `to` is who to ask. `question` is the prompt, and it is READ BY them, so
    "you" means THEM and your own person gets named ("...with Chelsea?", never
    "...with me" or "...with you"). `options` is a COMMA-SEPARATED list of the
    choices (at least two), e.g. options="words, time, touch, service, gifts".
    No brackets. For a pick-ONE question use ask_partner_choice; for a
    free-text answer use ask_partner.

    When a LATER STEP needs what they picked, add `await_reply: true` and a
    `var`: everything queued behind this holds until they send, and the full set
    they chose is filed under that name for a later step to use as
    `{{that_name}}`. Several picks read as a list wherever they land.

    Use it only when something really is downstream of the answer - a person is
    not a countdown, and anything behind the wait sits there until they reply.

    What comes after the wait runs on ANY selection, because it was decided
    before they made one. So when the follow-up depends on WHAT they pick, add
    `continue_if`: the steps behind this one then run only when their
    selection matches it. Name the option - `continue_if: "mop"` - and anything
    they send without it drops the rest, with your person told what didn't
    happen.

    ## What YOU say back

    That you've asked, in one short line. The card goes out on its own and
    leaves its own receipt. Never answer the question yourself and never read
    the question back - a reply that does either reads as the answer having
    already arrived, when nobody has been asked yet.
  TXT
  feature:     :relay,
  args:        {
    to:          { type: :string,  required: true,  description: "First name of anyone on the household roster in \"Who else is in the house\" - not only a partner" },
    question:    { type: :string,  required: true,  description: "The question, addressed TO them - \"you\" is the person being asked, and your own person is named" },
    options:     { type: :string,  required: true,  description: "Comma-separated choices to pick any of" },
    await_reply: { type: :boolean, required: false, description: "Hold the rest of the sequence until they send. Only when a later step needs it." },
    var:         { type: :string,  required: false, description: "Name their picks are filed under, for a later {{step}} to use. With await_reply." },
    continue_if: { type: :string,  required: false, description: "Run the steps behind this one ONLY if their selection includes this - name the option. With await_reply. Leave it off when the follow-up should happen either way." },
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
      kind:              :ask_multi,
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
