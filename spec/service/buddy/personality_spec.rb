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
      expect(prompt).to include("Don't just confirm and close")
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

    # Prod 1222: "Ohhh, got it." in answer to a preference nobody had argued about.
    it "reserves realization interjections for actually being corrected" do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).to include('"Ohhh" is a realization, not a reaction')
      expect(prompt).to include("they told you something")
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
