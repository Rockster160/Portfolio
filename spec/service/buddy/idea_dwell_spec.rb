require "rails_helper"

# The fixture is the real thing this exists because of: a 22-minute stretch in
# prod where a stashed kennel idea got weighed, narrowed, and corrected, and
# ended byte-for-byte as it was seeded.
RSpec.describe Buddy::IdeaDwell do
  let(:user) { User.me }
  let(:conversation) {
    ByteConversation.create!(user: user, mode: :buddy, name: "test", last_message_at: Time.current)
  }
  let!(:idea) {
    BuddyIdea.create!(
      user:     user,
      category: :home,
      status:   :active,
      summary:  "Kennel auto-open idea",
      body:     "automatic kennel open/close and treat dispenser with an inside sensor to tell if Whisper is in there",
    )
  }

  let(:kennel) {
    [
      [:them, "What would be the best ways to detect if she's in there or not?"],
      [:buddy, "A pressure mat inside, an IR break beam across the opening, or a little motion sensor tuned to the kennel mouth."],
      [:them, "A pressure mat seems excessive. Aren't those pretty pricey?"],
      [:buddy, "Yeah, a bit. They're usually more special hardware than a cheap sensor, so I'd lean beam or presence first."],
      [:them, "Would a presence sensor work well for that? I'm not very familiar with how those work."],
      [:buddy, "A presence sensor notices a body in a space even when nothing's moving much. Hands-off once it's tuned."],
      [:them, "I don't like the beam since it's just a toggle, and if she stuck her head in it would get mixed up."],
      [:buddy, "A beam is too binary for that job. For auto-close safety the shape is probably an mmWave sensor inside."],
      [:them, "We already have a door sensor for open and closed, and it's a sliding door that opens slowly."],
      [:buddy, "If the door state is covered and it moves slowly, the hard part is just presence, not the mechanics."],
      [:them, "Just to note, the door is NOT done yet. Just planned. The door sensor is in place though."],
      [:buddy, "Got it, the sensor's live and the door itself is still a plan. That makes presence matter even more."],
    ]
  }

  let(:elsewhere) {
    [
      [:them, "Mark the Switch Shell in the Agenda as done, please."],
      [:buddy, "Done. Switch Shell's off the agenda now."],
      [:them, "And what's the weather looking like tomorrow?"],
      [:buddy, "Mid seventies and clear all day."],
    ]
  }

  META = {
    them:     {},
    buddy:    { "kind" => "buddy" },
    doorbell: { "kind" => "buddy", "source" => "watch", "watch_id" => 18 },
  }.freeze

  def say(who, body, at: Time.current)
    conversation.byte_messages.create!(
      user:       user,
      direction:  who == :them ? :outbound : :inbound,
      state:      :delivered,
      body:       body,
      metadata:   META.fetch(who),
      created_at: at,
    )
  end

  # Laid down in order, oldest first. The gaps are deliberately absurd —
  # roughly an hour between messages — because nothing here is allowed to care.
  # A person thinking something through between other things is the case that
  # broke the first cut of this.
  def lay_down(lines)
    base = (lines.size + 1).hours.ago
    lines.each_with_index { |(who, body), i| say(who, body, at: base + (i + 1).hours) }
    conversation.update!(last_message_at: conversation.byte_messages.maximum(:created_at))
  end

  def stub_client(rounds)
    fake = FakeBuddyClient.new(rounds)
    allow(Buddy::GPT::Client).to receive(:new).and_return(fake)
    fake
  end

  describe ".settle!" do
    it "writes one companion note once they've moved on to something else" do
      lay_down(kennel + elsewhere)
      stub_client([{ text: "Landed on an mmWave presence sensor inside." }])

      note = described_class.settle!(conversation)

      expect(note).to be_persisted
      expect(note).to be_from_companion
      expect(note.body).to eq("Landed on an mmWave presence sensor inside.")
      expect(idea.reload.notes.count).to eq(1)
    end

    it "writes it when the caller already knows the stretch is over" do
      lay_down(kennel)
      stub_client([{ text: "Ruled out a pressure mat on cost." }])

      expect(described_class.settle!(conversation, over: true)).to be_persisted
    end

    it "leaves a live stretch alone" do
      lay_down(kennel)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_nil
      expect(idea.reload.notes).to be_empty
    end

    it "does not treat one unrelated question mid-thought as moving on" do
      lay_down(kennel + elsewhere.first(2))
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_nil
    end

    # The case that killed the first cut of this, which called a stretch over
    # after six quiet minutes: somebody picking a thought back up between other
    # things all day would have had every message look like the end of it.
    it "doesn't care how long they take between messages" do
      base = 3.days.ago
      kennel.each_with_index { |(who, body), i| say(who, body, at: base + (i * 5).hours) }
      conversation.update!(last_message_at: conversation.byte_messages.maximum(:created_at))
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_nil
      expect(idea.reload.notes).to be_empty
    end

    it "hands the model the idea as it stands and the stretch that was about it" do
      lay_down(kennel + elsewhere)
      fake = stub_client([{ text: "note" }])

      described_class.settle!(conversation)

      sent = fake.calls.first.input.first[:content]
      expect(sent).to include(idea.body)
      expect(sent).to include("the door is NOT done yet")
      expect(sent).to include("Them:", "Byte:")
    end

    it "writes nothing when the stretch added nothing worth keeping" do
      lay_down(kennel + elsewhere)
      stub_client([{ text: described_class::NOTHING }])

      expect(described_class.settle!(conversation)).to be_nil
      expect(idea.reload.notes).to be_empty
    end

    it "writes nothing when the model call fails" do
      lay_down(kennel + elsewhere)
      stub_client([{ error: "rate limited" }])

      expect(described_class.settle!(conversation)).to be_nil
      expect(idea.reload.notes).to be_empty
    end

    it "stays out of the way when the turn already wrote the note itself" do
      lay_down(kennel + elsewhere)
      idea.notes.create!(body: "Presence sensor it is.", source: :companion)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_nil
      expect(idea.reload.notes.count).to eq(1)
    end

    it "does not write a second note for a stretch it has already settled" do
      lay_down(kennel + elsewhere)
      stub_client([{ text: "Landed on presence." }])

      described_class.settle!(conversation)
      described_class.settle!(conversation)

      expect(idea.reload.notes.count).to eq(1)
    end

    it "ignores a conversation that only glanced at the idea" do
      lay_down([
        [:them, "Is Whisper in her kennel?"],
        [:buddy, "She is, yeah."],
      ] + elsewhere)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_nil
    end

    it "leaves an idea alone once it's been closed out" do
      lay_down(kennel + elsewhere)
      idea.update!(status: :done)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_nil
    end

    it "records its own cost separately from turns and compactions" do
      lay_down(kennel + elsewhere)
      stub_client([{ text: "note" }])

      described_class.settle!(conversation)

      row = BuddyUsage.last
      expect(row).to be_idea_note
      expect(row.byte_conversation_id).to eq(conversation.id)
      expect(row.cost_micros).to be > 0
    end

    # Counted, a run of doorbells partway through would shove two thirds of the
    # exchange out of a 12-message window and the stretch would read as a
    # passing mention.
    it "doesn't let watches and chips take up room in the window" do
      interrupted = kennel.first(8) +
                    Array.new(6) { [:doorbell, "🔔 Someone's at the door"] } +
                    kennel.last(4) + elsewhere
      lay_down(interrupted)
      stub_client([{ text: "Landed on presence." }])

      expect(described_class.settle!(conversation)).to be_persisted
    end
  end
end
