Buddy::Tools.register(
  name:        :message_partner,
  description: <<~TXT,
    Relay a message to the user's partner (or another household member)
    THROUGH their companion. Use whenever the user wants to tell / let / pass
    something along to someone else: "let Chelsea know I fed the dog", "tell
    Rocco I'm running late", "pass along that dinner's ready". Whatever you put
    in `message` is delivered word for word, so it has to read as a finished
    note rather than a terse instruction.

    HOW MUCH OF IT IS YOURS TO WRITE depends on how they said it:
    - They described what to convey - "tell her I fed the dog", "let him know
      I'm running late". The wording is yours. Phrase it as the natural note
      you'd pass along out loud.
    - They GAVE YOU THE WORDS - anything after "tell her:" or inside quotes,
      or a line that's plainly meant to arrive as written. Copy it EXACTLY.
      Capitals they chose are emphasis, punctuation is tone, emoji are theirs.
      "I like YOUR butt!" is not the same message as "I like your butt!" - the
      shouted word IS the joke, and smoothing it out quietly ruins what they
      were sending. Do not tidy, re-capitalize, re-punctuate, or improve it.

    When in doubt, send it as they typed it. Nobody has ever been annoyed that
    their words arrived intact.

    `to` is who it's for (a first name like "Chelsea", or "my wife"/"Rocco").
    It must be someone in the user's household - if you don't recognize the
    name, say you're not sure who they mean rather than guessing.

    This is one-way. If the user wants an ANSWER back, use ask_partner (open
    question), ask_partner_choice (pick one), or ask_partner_multi (pick any).
  TXT
  feature:     :relay,
  args:        {
    to:      { type: :string, required: true, description: "First name of anyone on the household roster in \"Who else is in the house\" - not only a partner" },
    message: { type: :string, required: true, description: "The note to send. Their exact words when they gave you words; your phrasing when they only gave you the gist." },
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
