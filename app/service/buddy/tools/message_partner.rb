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

    This sends it NOW. A message they want delivered LATER is the same message
    on a delay, and both forms exist - don't decline one and don't send it early
    instead:
    - At a time ("send it to her in five minutes", "tell him at 4") -
      `schedule_reminder` with `notify` set to them, and `text` written as the
      note itself.
    - When something HAPPENS ("when someone's at the door", "the next time a
      deploy finishes") - `remind_when` with `notify` set to them.
    Either way it arrives from this person, exactly as it would have here.

    A DELAY IS IN THE INSTRUCTION, NEVER IN THE NOTE. The only thing that makes
    it a later message is them telling you when to SEND it. A time sitting
    inside what they want said is part of the message, and holding the message
    until then is how it arrives too late to be any use:
    - "Tell Rocco I'll make supper at 6:00 tonight" - send it NOW. The 6:00 is
      when supper is. Delivering this at 6:00 tells him at supper time that
      supper is at supper time. (This one really happened - prod 3303.)
    - "Tell Chelsea I'm leaving at 4" - now, it's content.
    - "Remind Chelsea at 4 that I'm leaving" - `schedule_reminder`, it's framing.
    - "Let mom know the flight lands tomorrow" - now.
    When the sentence carries one time and you can't place it, it's content.
    Send it. They can always ask you to hold the next one.

    This is one-way. If the user wants an ANSWER back, use ask_partner (open
    question), ask_partner_choice (pick one), or ask_partner_multi (pick any).

    ## What YOU say back

    A short confirmation in your own voice - "sent", "she'll see it in a sec".
    That's the whole job. This tool sends the note and leaves its own receipt,
    so there is nothing left for your reply to carry.

    NEVER the note itself. "Tell Rocco I'm making salmon teriyaki bowls for
    supper, it'll be started at 6:00" came back as exactly that sentence, word
    for word, with the relay copy underneath it - so the same words appeared
    three times on her screen and not one of them said it had gone (prod
    3413-3417). Reading the note back tells them what they just typed and
    nothing about whether it left.
  TXT
  feature:     :relay,
  args:        {
    to:         { type: :string, required: true, description: "First name of anyone on the household roster in \"Who else is in the house\" - not only a partner" },
    message:    { type: :string, required: true, description: "The note to send. Their exact words when they gave you words; your phrasing when they only gave you the gist." },
    with_photo: { type: :boolean, required: false, default: false, description: "Send the picture that's already in this thread along with the note. Set it whenever they ask to send/show someone a PHOTO or camera frame - pull the frame up first (camera_snapshot) if it isn't here yet, then relay with this on." },
  },
  confirm:     ->(payload, ctx) {
    partner = ctx.resolve_household_user(payload[:to])
    raise "I'm not sure who #{payload[:to]} is" if partner.nil? || partner == ctx.user

    { summary: "Let #{partner.first_name} know: #{payload[:message]}", resolved: { to_user_id: partner.id, to_name: partner.first_name } }
  },
  label:       ->(payload, _ctx) { { title: "Message #{payload[:to_name]}", sub: payload[:message].to_s } },
  execute:     ->(payload, ctx) {
    partner = User.find(payload[:to_user_id])
    relay = Buddy::CompanionRelay.pass_along!(
      from:              ctx.user,
      to:                partner,
      text:              payload[:message].to_s,
      from_conversation: ctx.conversation,
    )
    # Nil when there was no recent picture to send. Reported, never glossed:
    # the note still went, and saying a photo went when none did is the exact
    # failure the camera turns kept producing.
    shared = (
      if payload[:with_photo]
        Buddy::CompanionRelay.share_photo!(from: ctx.user, to: partner, from_conversation: ctx.conversation)
      end
    )
    { relay_id: relay.id, to_name: payload[:to_name], photo_sent: shared.present?, photo_asked: !!payload[:with_photo] }
  },
  # Delivering to a partner is low-stakes and conversational, so it goes out
  # immediately and drops a receipt chip rather than a confirmation checkbox.
  auto:        true,
  receipt:     ->(result, _ctx) {
    if result[:photo_sent]
      "Sent #{result[:to_name]} the photo 📷"
    elsif result[:photo_asked]
      "Passed it along to #{result[:to_name]} 💬 (no recent picture here to send)"
    else
      "Passed it along to #{result[:to_name]} 💬"
    end
  },
)
