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
      # ...and Byte-only faces are not.
      expect(prompt).not_to include("`nerd`", "`uwu`")
      expect(prompt).not_to include("{{MOOD_BLOCK}}")
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
      moss = described_class.for(create(:user), conversation: buddy_convo(create(:user), "moss"), tone: :chelsea)

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

      expect(prompt).to include("Copy that.").and include("Affirmative.").and include("Acknowledged.")
      expect(prompt).to include("rotate these, never settle into one")
    end
  end

  describe ".for Byte's character" do
    def byte_prompt
      described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))
    end

    it "puts presence above being clever" do
      expect(byte_prompt).to include("Don't entertain with words")
      expect(byte_prompt).to include("Silence is comfortable")
    end

    it "leaves room to go off once in a while, so the calm isn't flatness" do
      expect(byte_prompt).to include("go off a bit")
      expect(byte_prompt).to include("if every message is a performance, none of them are")
    end

    it "makes praise cost something" do
      expect(byte_prompt).to include("Praise is earned")
      expect(byte_prompt).to include("Never congratulate someone for asking you to do a thing")
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
      moss = described_class.for(create(:user), conversation: buddy_convo(create(:user), "moss"), tone: :chelsea)

      expect(moss).not_to include("Blorp")
      expect(moss).not_to include("Soft and bouncy")
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

  describe ".for saved routines" do
    it "sends the model to run_routine instead of rebuilding the sequence" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("A routine they saved beats you rebuilding it")
      expect(prompt).to include("re-deriving it by hand is how a step quietly goes missing")
    end

    it "says capture_last is the only way to save what it just did" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("you can't see your own finished calls")
    end

    # Prod 1343: "prep my printer" got "I don't have a saved prep my printer
    # routine yet" while the Jil task that does exactly that sat in jil_triggers.
    it "says a missing routine means do it the ordinary way, not announce the gap" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("never the answer to being asked for it")
      expect(prompt).to include("your bookkeeping, not theirs")
    end

    # Prod 1362: "it's supposed to complete the chore 3 times, there shouldn't be
    # an event" was a description of the saved steps. Buddy ran them on live data
    # instead, and left the routine exactly as wrong as it was.
    it "says correcting a routine edits the routine rather than running it" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("A correction to a ROUTINE edits the routine, not the world")
      expect(prompt).to include("describing what it SHOULD do")
    end

    # Prod 1371: a bare "water cup" — the exact name of a routine they'd saved
    # ninety seconds earlier — got "Hmm, I don't quite follow".
    it "says to check the routines list before shrugging at a short phrase" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("before you ever tell them you don't follow a short phrase")
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
  end

  describe ".for list placement" do
    it "sends the model to `lists` for real sections before filing an item" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include("Pass the exact section name as `section`")
      expect(prompt).to include("Only fall back to `category` for the placement itself when no section matches")
    end
  end
end
