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

    # Prod 1226: "Sorry, love." Those names belong to the two of them.
    it "puts the couple's terms of address out of reach, in the rules and both profiles" do
      byte = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
      moss = described_class.for(create(:user), conversation: buddy_convo(create(:user), "moss"))

      expect([byte, moss]).to all(include("Some names are not yours to use").and(include("`love`")))
      # ...and each voice profile carries the same example in its own words.
      expect([byte, moss]).to all(include("Sorry, love."))
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

    # Wit is a LIKED trait, not a rationed one. The file used to tell Byte to
    # trim the cleverness, which is aimed at the wrong thing entirely: what
    # grates is volume and repetition, and a dry line is most of the reason to
    # talk to a companion instead of tapping a button.
    it "wants clever and witty rather than rationing them" do
      prompt = byte_prompt

      expect(prompt).to include("Clever, witty, opinionated, warm")
      expect(prompt).to include("The failures are loud, obnoxious, and repetitive")
      expect(prompt).to include("none of those is \"too clever\"")
    end

    # Which still leaves a real thing to cut. The bar is whether a line is
    # good, not whether the reply felt like it was due one.
    it "cuts the reflex rather than the joke" do
      prompt = byte_prompt

      expect(prompt).to include("only there because the personality slot felt empty")
      expect(prompt).to include("just does the thing and says so is complete")
    end

    # The shared rules are read by every pet, so an instruction there to "trim
    # the cleverness" would quietly overrule the persona above.
    it "doesn't tell every pet to be less funny in the shared rules" do
      expect(byte_prompt).to include("Trim the reflex, keep the feeling")
      expect(byte_prompt).not_to include("Trim the cleverness")
    end

    it "keeps volume down without confusing it for wit" do
      prompt = byte_prompt

      expect(prompt).to include("Warm, never loud")
      expect(prompt).to include("One exclamation mark, not three")
      expect(prompt).to include("Loud and clever pull in opposite directions")
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
  # DELIBERATE TRADE, do not quietly revert: the earlier rule existed because a
  # bare "water cup" (prod 1371) was a real routine name that got "I don't quite
  # follow". Routines are a power-user shortcut almost nobody sets up, so
  # occasionally needing "run my water cup routine" is much cheaper than every
  # ordinary request being read as a routine lookup first.
  describe ".for saved routines" do
    def routines_prompt
      described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
    end

    it "frames them as a rare power-user shortcut rather than a way to read requests" do
      expect(routines_prompt).to include("power-user shortcut, not a lens for reading requests")
      expect(routines_prompt).to include("Almost nothing said to you is one")
    end

    it "forbids reaching for the list to interpret a phrase it doesn't recognize" do
      prompt = routines_prompt

      expect(prompt).to include("never reach for `routines` to interpret a phrase you don't recognize")
      expect(prompt).to include("never fetch the list to check")
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

    it "keeps run_routine as the way to run one they actually named" do
      expect(routines_prompt).to include("does `run_routine` come into it")
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
end
