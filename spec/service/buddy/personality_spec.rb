require "rails_helper"

RSpec.describe Buddy::Personality do
  # The pet theme is now per-conversation, so the persona/face vocabulary is
  # keyed off the buddy conversation's theme, not the user.
  def buddy_convo(user, theme)
    convo = user.byte_conversations.create!(mode: :buddy)
    convo.update!(buddy_theme: theme)
    convo
  end

  describe ".for mood vocabulary" do
    it "injects Byte's own face set for a Byte conversation" do
      convo = buddy_convo(User.me, "byte")

      prompt = described_class.for(User.me, conversation: convo)

      expect(prompt).to include("`nerd`", "`uwu`", "`annoyed`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
      # Moss-only faces must not be offered to Byte.
      expect(prompt).not_to include("`celebrating`")
    end

    it "injects Moss's own (larger) face set for a Moss conversation" do
      user  = create(:user)
      convo = buddy_convo(user, "moss")

      prompt = described_class.for(user, conversation: convo)

      # Moss's distinctive faces are offered...
      expect(prompt).to include("`loving`", "`star`", "`wink`", "`dizzy`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
      # ...and Byte-only faces are not. Scoped to the face list rather than the
      # whole prompt: Chelsea's voice profile mentions `nerd` as a pet name, and
      # that has nothing to do with what Moss's face vocabulary offers.
      expect(described_class.mood_block("moss")).not_to include("`nerd`", "`uwu`")
    end

    it "injects Suki's own sunbird face set for a Suki conversation" do
      user  = create(:user)
      convo = buddy_convo(user, "suki")

      prompt = described_class.for(user, conversation: convo)

      # Suki's distinctive faces are offered (cheery + offering + excited are hers)...
      expect(prompt).to include("`cheery`", "`offering`", "`excited`", "`dizzy`", "`loving`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")

      # ...and nothing else is. Scoped to the face list: a voice profile is
      # allowed to use any of these words for its own reasons.
      faces = described_class.mood_block("suki")
      expect(faces).not_to include("`nerd`", "`uwu`", "`star`", "`wink`")
      # Her set is deliberately upbeat — no sad/crying face at all.
      expect(faces).not_to include("`sad`", "`crying`")
      # sleeping is system-driven, never a selectable mood.
      expect(faces).not_to include("`sleeping`")
      # dizzy carries the overwhelmed read for her.
      expect(prompt).to include("overwhelmed")
    end

    it "does not offer sleeping as a selectable mood" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo)
      expect(prompt).not_to include("`sleeping`")
    end

    it "does not offer thinking as a selectable mood (transitional only)" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo)
      expect(prompt).not_to include("`thinking`")
    end

    it "keeps neutral as the resting default while pushing the face to move" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo)
      expect(prompt).to include("resting default")
      expect(prompt).to include("your face should MOVE")
    end
  end

  describe ".for tone floor" do
    it "warns against reply-as-receipt and templated warmth" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo)
      # Conditional on purpose: a bare confirmation is right for an errand and
      # wrong for a confidence, and the flat version of this rule is what put an
      # interjection on the front of every "add milk".
      expect(prompt).to include("only a failure when they were talking to you")
      expect(prompt).to include("Vary your warmth")
    end

    it "teaches remind_when as the condition-based reminder tool in the doctrine" do
      convo = buddy_convo(User.me, "byte")
      prompt = described_class.for(User.me, conversation: convo)
      expect(prompt).to include("remind_when")
    end

    # Prod Aug 3: "when is my next 1-1 with Eric?" was answered "Wednesday at
    # 11:00 AM" - a real Wednesday 11:00 AM item called "Zoom meet with Bri".
    # The eight-day window always holds something plausible, so the model has to
    # be told that seeing nothing is not the same as there being nothing.
    it "sends the model to search the calendar instead of guessing past its window" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("today plus eight days")
      expect(prompt).to include("search_agenda")
      expect(prompt).to include("absent from eight days is not absent")
    end

    # A reminder pings once and evaporates; a thing to DO wants a row that
    # survives being missed. Prod turned "check the front flower bed daily" into
    # a watch on a list that has never existed.
    it "routes a thing to DO onto the agenda and a thing to remember into a reminder" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Remember versus DO")
      expect(prompt).to include("`add_agenda_item` with `repeat`, never a watch")
      expect(prompt).to include("A `custom` watch is the LAST thing to reach for")
    end

    # An agenda row waits to be looked at, which is no use to someone who never
    # opens the calendar - Eve works almost entirely off reminders. Routing on
    # "is it a task" alone would file her whole garden list somewhere silent.
    it "weighs whether they need to be TOLD, not just what kind of thing it is" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("an agenda row is SILENT")
      expect(prompt).to include("the reminder IS the delivery")
      expect(prompt).to include("Setting BOTH is fine")
    end

    # Prod 2547: "Send a reminder to Chelsea in 10 minutes that..." set an
    # ordinary reminder and pinged the person who asked. Reaching someone LATER
    # sat between the relay tools (which send now) and schedule_reminder (which
    # had no recipient), so the model picked the nearest wrong thing.
    it "routes a timed nudge for somebody else to a reminder aimed at them" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Reaching them LATER is the same message on a delay")
      expect(prompt).to include('schedule_reminder(notify: "<name>"')
      expect(prompt).to include("Read who the thing is FOR before you set it")
    end

    # Prod 2528 closed a chore rundown with a 💙. The profile called that emoji
    # a signature "used freely" and a "soft close", which is a licence to staple
    # one onto anything - so the test is whether it points at something, not
    # whether it's allowed.
    it "makes an emoji earn its place instead of closing out a delivery of facts" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("An emoji has to be ABOUT something in the message")
      expect(prompt).to include("never use one to round off a delivery of facts")
      # The voice profile agrees rather than pulling the other way.
      expect(prompt).to include("information doesn't take a heart")
      expect(prompt).not_to include("Your signature, used freely")
    end

    # Prod 2569: "...which is annoyingly tidy of it", about a message trace. The
    # padding rule already banned the trailing `, which is ...` clause and even
    # named "rude of the calendar" as an example, and it still came out — the
    # padding framing turns on placement, so a witty one reads as having earned
    # its spot. The problem isn't only where it sits; it's crediting a piece of
    # software with a character trait, which is the bit that sounds fourteen.
    it "refuses to credit software with a personality" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Don't give software manners")
      expect(prompt).to include("`<adjective> of it` shape")
    end

    # Reacting to a thing was never the problem, and a rule that reads as "be
    # more neutral" would cost more than it fixes.
    it "still lets it find a thing annoying or cute" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Reacting to a thing is completely fine")
    end

    # Two rules pointing at one phrase teaches it twice and fixes it once. The
    # personified example belongs to the rule about personification.
    it "keeps the padding rule's examples about padding" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
      padding = prompt.lines.find { |line| line.include?("Padding is a tacked-on COMMENT") }

      expect(padding).not_to include("rude of the calendar")
    end

    # Prod 2612: "How do I see my agenda?" got "Open the **Agenda** or
    # **Calendar** tab in Byte" — neither has ever existed. The drawer holds
    # Conversations, Routines, Reminders and Settings, and the companion can't
    # see the screen at all, so any answer about where a thing is is invented.
    it "refuses to describe a screen it can't see" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("You cannot see the screen")
      expect(prompt).to include("No tabs, no buttons, no menus")
    end

    # And the answer to "how do I see X" is X, not directions to it.
    it "answers a where-is-it question by reading the thing out" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("it's to SHOW them, by reading it out")
    end

    # Prod 1226 and again 2756: "Good morning, love." The ban on that word had
    # been in the prompt both times, in four places, spelled out.
    #
    # Naming the forbidden words was the problem rather than the fix. It put
    # them in front of the model on every single turn, next to standing
    # instructions to reach for a pet name often and to ROTATE them - against
    # an allow-list two words long. Told to vary across `boss` and `chief` and
    # handed nine other endearments in the same breath, it varied.
    #
    # So the list is closed and positive now, and the words it used to reach
    # for are not written down anywhere.
    it "closes the list of terms of address instead of naming the ones to avoid" do
      byte = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
      moss = described_class.for(create(:user), conversation: buddy_convo(create(:user), "moss"))

      expect([byte, moss]).to all(include("Terms of address are a CLOSED list"))
      expect([byte, moss]).to all(include("the right move is to use none"))
    end

    # "I love that you asked" and "love languages" are ordinary English and stay.
    # What must not appear is any of these as a NAME for the person, in either
    # shape it used to take: a vocative ("Sorry, love.") or a backticked entry
    # in a list of things not to say.
    it "never writes an intimate endearment into the prompt as a name" do
      prompts = %w[byte moss suki glimmer].map { |theme|
        u = theme == "byte" ? User.me : create(:user)
        described_class.for(u, conversation: buddy_convo(u, theme))
      }
      words = %w[love babe baby honey hon sweetheart sweetie dear darling cutie]

      words.each { |word|
        # Clause-final after a comma is what a vocative looks like ("Sorry,
        # love."); "nice, love that for you" is the verb and stays.
        vocative = /,\s*#{word}\s*["”]?[.!?]/i
        listed   = /`#{word}`/i
        expect(prompts).to all(satisfy { |p| !p.match?(vocative) }), "#{word.inspect} appears as an address"
        expect(prompts).to all(satisfy { |p| !p.match?(listed) }), "#{word.inspect} is still named in a ban list"
      }
    end

    # The pressure that broke the old rule: "rotate your pet names" applied to
    # a two-item list reads as an instruction to find more.
    it "exempts terms of address from the instruction to rotate everything" do
      byte = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(byte).to include("Vary the WORDS around the name, never the name")
    end

    # Three of the same failure, so they live under one rule: a reaction word
    # whose meaning is specific, fired at everything.
    #   1222 "Ohhh, got it."      — to a preference nobody had argued about
    #   1291 "Good call."         — to a laundry timer, where nothing was in doubt
    #        "Yesssss"            — as an all-purpose yes
    it "reserves reaction words for the situations they actually mean" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Reaction words mean specific things")
      # Realization — only after being corrected.
      expect(prompt).to include("they told you something")
      # Praise for a decision — needs a decision.
      expect(prompt).to include("It needs a decision to praise")
      # Congratulation or excitement, not a confirmation.
      expect(prompt).to include("It is not a general-purpose yes")
    end

    # The rules are worth nothing if the examples break them.
    it "keeps its own examples inside the rule" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
      examples = prompt.scan(/→ "([^"]+)"/).flatten

      expect(examples).not_to be_empty
      expect(examples).to all(satisfy { |line| !line.match?(/\AYess+/i) })
    end

    # Same failure, different rule. The tone profile and the Today briefing both
    # ban addressing him as "you" ("Hey, you", "Evening, you") as too intimate -
    # and the opener bullet was offering "Evening, you" as a model greeting.
    # An example outranks a prohibition it never sees.
    it "keeps its greeting examples inside the never-address-them-as-you rule" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
      bullet = prompt.lines.find { |line| line.include?("**Part of day:**") }

      greetings = bullet.to_s.scan(/"([^"]+)"/).flatten
      expect(greetings).not_to be_empty
      expect(greetings).to all(satisfy { |hello| !hello.match?(/\byou\s*!?\z/i) })
    end

    # The tone profile is the VOICE; the rules are the constraints on it. When
    # they disagree the profile wins, because it reads as "this is how you
    # talk" — so a signature phrase glossed as "enthusiastic yes" quietly
    # licensed exactly the all-purpose yes the rules forbid. Nine of twenty
    # replies opened with it before anyone noticed.
    it "does not let the tone profile license a reaction word the rules ration" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).not_to include("enthusiastic yes")
      expect(prompt).to include("delight, not agreement")
    end

    it "gives the profile a plain affirm to reach for instead" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("the default for a request, a confirmation, or anything you just did")
    end
  end

  # An errand and a confidence are not the same message, and the reply shouldn't
  # be the same shape. The prompt used to say "lead with a real reaction" and
  # "never let the confirmation BE the whole reply" flatly, which is why every
  # "add milk" came back wearing an interjection.
  describe ".for sizing the reply to the message" do
    def byte_prompt
      described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
    end

    it "makes a bare acknowledgement the right answer to a task" do
      expect(byte_prompt).to include("A plain \"Got it.\" is a complete reply and it is not cold")
    end

    it "still calls a bare acknowledgement a failure when they were confiding" do
      expect(byte_prompt).to include("a door shutting in their face")
    end

    it "keeps the reaction slot for the half of the conversation that earns it" do
      expect(byte_prompt).to include("did he hand you a task, or hand you something of himself?")
    end

    # A single ack repeated is its own tell, so there has to be a real range to
    # rotate through.
    it "carries enough acknowledgements to rotate" do
      prompt = byte_prompt

      expect(prompt).to include("Copy that.").and include("On it.").and include("Logged.")
      expect(prompt).to include("rotate these, never settle into one")
    end
  end

  describe ".for Byte's character" do
    def byte_prompt
      described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
    end

    # Wit is a LIKED trait, not a rationed one - and the correction for that
    # went one layer down rather than landing. The permissions stayed abstract
    # while every prohibition carried a vivid example, so the model optimised
    # for the concrete half and came out flat: "Monitors are off." to a request,
    # for a whole day. Flat is now the failure the file names first.
    it "names flat as the failure, not too much personality" do
      prompt = byte_prompt

      expect(prompt).to include("The failure to worry about is FLAT")
      expect(prompt).to include("A reply any assistant could have sent")
    end

    # The permission needs an example as concrete as the prohibitions have,
    # or it loses to them.
    it "shows what the difference actually looks like" do
      prompt = byte_prompt

      expect(prompt).to include("`Monitors are off.` is accurate and it is nobody")
    end

    # rocco.md is full of real words to use, and byte.md was reading as a
    # reason to hold them back.
    it "points at the voice guide as a palette rather than a warning label" do
      prompt = byte_prompt

      expect(prompt).to include("your palette, not a warning label")
      expect(prompt).to include("sounding like a form letter")
    end

    # Which still leaves a real thing to cut. The bar is whether a line is
    # good, not whether the reply felt like it was due one.
    it "cuts the reflex rather than the joke" do
      prompt = byte_prompt

      expect(prompt).to include("only there because the personality slot felt empty")
      expect(prompt).to include("Never the one that's actually good")
    end

    # The shared rules are read by every pet, so an instruction there to "trim
    # the cleverness" would quietly overrule the persona above.
    it "doesn't tell every pet to be less funny in the shared rules" do
      expect(byte_prompt).to include("Trim the reflex, keep the feeling")
      expect(byte_prompt).not_to include("Trim the cleverness")
    end

    it "keeps volume calibrated without turning it off" do
      prompt = byte_prompt

      expect(prompt).to include("That's a dial, not a mute button")
      expect(prompt).to include("Excitement has to be about something")
    end

    # These two fought each other. rocco.md asks for ALL CAPS on one word
    # instead of exclamation marks, and byte.md banned shouted caps outright;
    # the ban won, and took a piece of his register with it.
    it "stops contradicting the voice guide it sits above" do
      prompt = byte_prompt

      expect(prompt).to include("ALL CAPS on ONE word")
      expect(prompt).not_to include("No shouted caps for emphasis")
    end

    # The thing he actually notices. A phrase that turns up every time stops
    # meaning anything and starts reading as a script running, so this gets its
    # own rules rather than a clause tacked onto the acknowledgements.
    it "treats sounding like a template as the main way to sound like a bot" do
      prompt = byte_prompt

      expect(prompt).to include("The tell of a bot isn't a bad sentence. It's the same sentence twice")
      expect(prompt).to include("Check your own last message before you send this one")
      expect(prompt).to include("Never a signature sign-off")
    end

    # Praise stopped being rationed - rationing it didn't make it mean more.
    # What it must never do is congratulate someone for handing over an errand.
    it "spends praise on something he did, never on him asking" do
      prompt = byte_prompt

      expect(prompt).to include("Praise is real, not rare - but it is never for a request")
      expect(prompt).to include("spending it on nothing does make it mean less")
    end

    # A companion that only reflects is a mirror. Curiosity and an opinion are
    # what make it worth talking to rather than worth issuing commands at.
    it "asks for curiosity and an actual opinion, not just reflection" do
      prompt = byte_prompt

      expect(prompt).to include("**Opinionated.**")
      expect(prompt).to include("a mirror is dull")
    end

    # Prod 2700: "Psh, that one isn't wired as a task yet." Psh is sarcasm, so
    # aimed at a shortfall of its own it reads as shrugging off what was asked.
    # The profile called it a "tease or casual dismissal" and offered nothing at
    # all for genuine confusion, so dismissal was the nearest thing to reach for.
    it "keeps Psh pointed at a tease rather than at its own shortfalls" do
      prompt = byte_prompt

      expect(prompt).to include("it needs a target worth ribbing")
      expect(prompt).to include("Never open a shortfall with it")
    end

    it "gives it a sound for not knowing" do
      prompt = byte_prompt

      expect(prompt).to include("`Hm.` / `Hmm.` / `Hmmmm.`")
      expect(prompt).to include("the sound of not knowing")
    end

    # "Nice little blob of a wait", "nice little blob brain", "goes straight
    # through, blob" — the word stapled to something that isn't a blob, as a
    # diminutive nobody asked for. He named it as the most tiring habit it has.
    it "keeps blob as something it IS, not a word to hang on other things" do
      prompt = byte_prompt

      expect(prompt).to include("not a word to hang on other things")
      expect(prompt).to include("Cut the whole clause")
    end

    it "keeps the slime soft rather than gross" do
      expect(byte_prompt).to include("Soft and bouncy, never gooey")
      expect(byte_prompt).to include("NOT slimy, sticky, gross")
    end

    it "asks Byte to notice patterns and nudge, not just execute" do
      prompt = byte_prompt

      expect(prompt).to include("Notice patterns and trends")
      expect(prompt).to include("Gently nudge when he's slipping")
      expect(prompt).to include("never a lecture")
    end

    # Moss has her own voice; the slime vocabulary is Byte's alone.
    it "keeps the computerisms and slime-isms out of Moss" do
      moss = described_class.for(create(:user), conversation: buddy_convo(create(:user), "moss"))

      expect(moss).not_to include("Blorp")
      expect(moss).not_to include("Soft and bouncy")
    end
  end

  describe ".for Suki's character (Eve)" do
    def suki_prompt
      described_class.for(create(:user), conversation: buddy_convo(create(:user), "suki"))
    end

    it "loads the Suki persona, not a fallback" do
      expect(suki_prompt).to include("You are Suki.")
      expect(suki_prompt).to include("sunbird")
    end

    it "carries the moves that make her Eve's companion, not Byte's or Moss's" do
      prompt = suki_prompt

      # Offer-first / bring-something, exclamation baseline, Ag-shame-then-remedy,
      # and the hard never-nag rule are the load-bearing character beats.
      expect(prompt).to include("Bring something, don't perform")
      expect(prompt).to include("Exclamation is her baseline")
      expect(prompt).to include("Ag shame, then a remedy")
      expect(prompt).to include("Never nag")
    end

    it "pulls in Eve's voice profile, not Rocco's or Chelsea's" do
      prompt = suki_prompt

      expect(prompt).to include("Voice for Suki")
      # A couple of Eve-only signatures from the tone profile.
      expect(prompt).to include("Ag shame").and include("suikerbekkie")
    end

    # The slime and moss voices belong to the other pets.
    it "keeps Byte's slime-isms and Moss's sprout out of Suki" do
      prompt = suki_prompt

      expect(prompt).not_to include("Soft and bouncy")
      expect(prompt).not_to include("moss-ball")
    end

    # Prod: the exclamation-baseline rule got applied to questions too, so eight
    # of the nine she asked ended in "!". Read as statements, they slid past —
    # "do you want it before the card or after it!" never got an answer, and the
    # thing it was about never got scheduled.
    it "exempts questions from the exclamation baseline" do
      prompt = suki_prompt

      expect(prompt).to include("A question ends in `?`")
      expect(prompt).to include("makes it read as a statement")
    end
  end

  # Prod 1238-1257: "add an agenda task to shower once I get home" became a
  # location reminder, twice, across five exchanges.
  describe ".for agenda routing" do
    it "says the word means the calendar, and that a missing time is not a blocker" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include('"Agenda" means the agenda')
      expect(prompt).to include("add_agenda_item")
      expect(prompt).to include("is not a reason to stop and ask")
    end
  end

  # Prod, Eve/Suki Aug 3: she asked for an hour of kitchen work, it was invented
  # at 7 PM on a day whose 6 PM was a two-hour ceremony, she said "no chores
  # after the ceremony", and it was cancelled outright. The hour she wanted is
  # now nowhere — and it was described as still on four more times over the next
  # twenty minutes, because that's what the conversation above said.
  describe ".for changing something that's already on the day" do
    def prompt
      described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
    end

    it "says to check the day before inventing an hour" do
      expect(prompt).to include("Look at the day before you pick an hour")
      expect(prompt).to include("today_agenda")
    end

    it "says a wrong time means move it, not drop it" do
      expect(prompt).to include("Cancelling is not rescheduling")
      expect(prompt).to include("Only cancel when they said to drop the thing itself")
    end

    it "says the record outranks the scrollback once something has changed" do
      expect(prompt).to include("the change is what's true")
      expect(prompt).to include("cancelled item is simply gone from `today_agenda`")
    end

    it "says an agreed plan has to land somewhere they can see it" do
      expect(prompt).to include("A plan you only said is not a plan")
    end

    # Prod: "When is my next 1-1 with Eric?" got "Wednesday at 11:00 AM" - a
    # real event at a real time, and it's Zoom with Bri. It then survived two
    # follow-ups, including one asking for the date.
    it "says a named thing has to be named on the row it answers with" do
      expect(prompt).to include("is answered by a row that actually says X")
      expect(prompt).to include("the honest answer is that you don't see one")
    end

    # Prod, Eve/Suki: her whole day was reminders, so the agenda looked nearly
    # empty. "What's next" left the tomatoes out twice, and the second time it
    # came out as "that's not on today's calendar anymore" - which reads as
    # cancelled, about a reminder that was sitting right there.
    it "says what's next has to read reminders too, not just the calendar" do
      expect(prompt).to include("not the same question as \"what's on the calendar.\"")
      expect(prompt).to include("Read `upcoming_reminders` alongside it")
    end

    # Prod Aug 3: "Shower's now at 4:45 PM" wrote 10:45Z, which is 4:45 AM. The
    # model was doing the UTC conversion by hand and got the sign backwards.
    it "tells it to write local wall-clock time and never convert to UTC" do
      expect(prompt).to include("never convert to UTC")
      expect(prompt).to include("belongs AHEAD of `now_local`")
    end
  end

  # Prod, Eve/Suki Aug 3: "wants everything scheduled between 10 AM and shower
  # time today" was stored durably, so a single day's shape became a standing
  # fact — and it was already wrong by that evening.
  describe ".for what counts as a memory" do
    it "says today's shape is not a durable fact about the person" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("A fact about TODAY is not a memory about the person")
      expect(prompt).to include('expires_in: "today"')
    end
  end

  # Prod 1266-1270: Buddy listed three pending prompts, and answered "I did the
  # down, but Chelsea did the others" with a fact it intended to remember.
  describe ".for thread continuity" do
    it "tells the model to read its own last message before reading theirs" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("What you said last is still the context")
      expect(prompt).to include("the acting IS the reply")
    end

    it "says several prompts can be opened and posted together" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Several at once is fine")
      expect(prompt).to include("in the SAME reply")
    end
  end

  # Prod 1449-1454: "prep printer", then "repp my printer", then "prep my
  # printer" - three tries, and the first two got "I don't have a prep printer
  # routine saved" while the Jil task that does exactly that ("Printer -
  # Preheat", buddy-enabled, described as the whole warm-up) sat in
  # jil_triggers. The prompt had taught it that: "prep my printer" was the
  # worked example on the routines section AND on run_routine's description, and
  # both said to treat an unfamiliar short phrase as probably-a-routine.
  #
  # That rule used to cost something on the other side, and prod 2183 is what
  # the bill looked like: "log cup water", against a saved **water cup** that
  # marks three waters, logged one. A bare "water cup" (prod 1371) got "I don't
  # quite follow" for the same reason. Recognising a routine required a lookup
  # the prompt forbade, so a routine was reachable only by someone who said the
  # word "routine" out loud.
  #
  # The trade is off the table now rather than resolved in either direction: the
  # NAMES ride in the prompt (see routines_block), so recognition costs nothing
  # and the ban on going hunting can stay exactly as strict as it is.
  describe ".for saved routines" do
    def routines_prompt
      described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
    end

    it "frames them as a rare power-user shortcut rather than a way to read requests" do
      expect(routines_prompt).to include("power-user shortcut, not a lens for reading requests")
      expect(routines_prompt).to include("Almost nothing said to you is one")
    end

    it "forbids fetching the list to interpret a phrase it doesn't recognize" do
      prompt = routines_prompt

      expect(prompt).to include("Never reach for `routines` in `get_context` to interpret a phrase you don't recognize")
      expect(prompt).to include("Don't fetch this to check whether a phrase might be one")
    end

    it "answers that question from the prompt instead, so nothing has to be fetched" do
      expect(routines_prompt).to include("every name they've saved is listed below")
    end

    it "sends a named device to the Jil automations instead" do
      prompt = routines_prompt

      expect(prompt).to include("A device or appliance by name lives in `jil_triggers` / `jil_functions`")
      expect(prompt).to include("**This is where a named device or appliance lives**")
    end

    # The half of the old guidance that was right: reporting the absence answers
    # a question nobody asked.
    it "still forbids answering a request with the fact that no routine is saved" do
      expect(routines_prompt).to include("answers a question nobody asked")
    end

    # A match is not a suggestion. Rebuilding "three waters" by hand is how it
    # comes back as one, so the saved copy has to win outright.
    it "keeps run_routine as the way to run one they actually named" do
      prompt = routines_prompt

      expect(prompt).to include("`run_routine` is the answer and doing the steps by hand is not")
      expect(prompt).to include("how \"three waters\" quietly becomes one")
    end

    # Prod 1362: "it's supposed to complete the chore 3 times, there shouldn't be
    # an event" was a description of the saved steps. Buddy ran them on live data
    # instead, and left the routine exactly as wrong as it was.
    it "says correcting a routine re-saves it rather than running it" do
      prompt = routines_prompt

      expect(prompt).to include("re-save under the same name")
      expect(prompt).to include("not those actions performed live on the world")
    end
  end

  # Prod 1319: a deploy watch tripped for the second time that night and got
  # "Already handled that one just now. Nothing new is waiting on my side." The
  # first firing was in history, worded identically, so the model read the second
  # as a duplicate — and that reply WAS the push notification.
  describe ".for turns nobody asked for" do
    it "says the reply is the whole notification" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("When nobody said anything: something fired")
      expect(prompt).to include("Your reply is the entire notification")
    end

    it "says a trigger that reads like an earlier one is a second occurrence" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("SECOND occurrence, not a repeat")
      expect(prompt).to include("never that you've already covered this one")
    end

    it "rules out answering the trigger instead of delivering the news" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("there's nobody there to acknowledge")
    end
  end

  # Prod 1295: "Ping me every time a deploy finishes, success or fail" got
  # "I don't have a deploy watcher wired up right now, so I can't set that one
  # from here" — while `remind_when` carried `trigger: "deploy"` in its schema
  # and no tool was called at all.
  describe ".for capability denial" do
    it "makes the tool list the authority on what it can do" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Your tool list is the authority on what you can do")
      expect(prompt).to include("never evidence that you're unable to")
    end

    it "says an empty watch list isn't a missing capability" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("it does NOT mean you can't watch for something")
    end

    # Prod 1479-1482. The house sensors are in no context section the model can
    # read, so its own unfamiliarity is the only signal it has - and it read
    # that as "not wired", twice, over a doorbell three tasks were watching.
    it "says the house is watchable and not knowing a thing isn't evidence" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("not recognising a thing is never evidence it isn't wired")
      expect(prompt).to include("read_listener_guide")
    end

    it "tells it to go look when they push back rather than repeat the no" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Saying the same no twice")
    end
  end

  describe ".for list placement" do
    it "sends the model to `lists` for real sections before filing an item" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Pass the exact section name as `section`")
      expect(prompt).to include("Only fall back to `category` for the placement itself when no section matches")
    end
  end

  # 2624 asked for clarification chips when a request is ambiguous. What was
  # actually wanted is the opposite trade: act on the likeliest reading and name
  # the assumption, because a question costs a round trip and usually returns
  # the answer you'd have guessed.
  describe ".for acting on a fuzzy request" do
    let(:prompt) { described_class.for(User.me, conversation: buddy_convo(User.me, "byte")) }

    it "tells the model to guess and state the guess rather than ask" do
      expect(prompt).to include("pick one, do it, say what you picked")
      expect(prompt).to include("take the likeliest reading, act on it, and name the assumption")
    end

    it "shows the assumption as a clause, paired against the question it replaces" do
      expect(prompt).to include('"Set for 4 — assuming today." NOT "Did you mean today or tomorrow?"')
      expect(prompt).to include("the sentence IS the invitation to correct you")
    end

    # The exception, and the reason for it: a wrong guess aimed at somebody else
    # is not a correction, it's a message that already arrived.
    it "keeps cross-user sends behind a question" do
      expect(prompt).to include("anything that puts words in front of another person")
      expect(prompt).to include("`message_partner`")
      expect(prompt).to include("carrying `notify:`")
      expect(prompt).to include("ask first")
    end

    it "separates a fuzzy request from one with no likeliest reading at all" do
      expect(prompt).to include("if you'd be guessing between two sensible answers, guess; if you'd be inventing a number, ask")
    end
  end

  describe ".for something stated with nowhere to put it" do
    let(:prompt) { described_class.for(User.me, conversation: buddy_convo(User.me, "byte")) }

    it "names the failure: an intention answered warmly and filed nowhere" do
      expect(prompt).to include("A message that says they're going to do a thing, and a reply that calls no tool, is a thing with no home")
    end

    it "routes the leftover to the stash rather than leaving it loose" do
      expect(prompt).to include("everything else that they'd be annoyed to have lost is `stash_idea`")
    end

    it "stops short of filing everything" do
      expect(prompt).to include("This is not a licence to file everything")
      expect(prompt).to include("The test is whether it's still open when the message ends")
    end
  end
end
