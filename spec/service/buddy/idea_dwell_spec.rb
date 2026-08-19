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
    BuddyMemory.create!(
      kind:     :stash,
      user:     user,
      category: :home,
      status:   :active,
      summary:  "Kennel auto-open idea",
      content:     "automatic kennel open/close and treat dispenser with an inside sensor to tell if Whisper is in there",
    )
  }

  let(:kennel) {
    [
      [:them, "What would be the best ways to detect if Whisper's in the kennel or not?"],
      [:buddy, "A pressure mat inside, an IR break beam across the opening, or a sensor at the kennel mouth."],
      [:them, "A pressure mat seems excessive. Aren't those pretty pricey?"],
      [:buddy, "A bit. More special hardware than a cheap sensor, so I'd lean beam or presence first."],
      [:them, "Would a presence sensor work well for that? I'm not familiar with how those work."],
      [:buddy, "It notices a body inside a space even when nothing's moving much. Hands-off once tuned."],
      [:them, "I don't like the beam, it's just a toggle - if Whisper poked her head in it'd get mixed up."],
      [:buddy, "Too binary. For auto-close safety the shape is an mmWave presence sensor inside the kennel."],
      [:them, "We already have a door sensor for open and closed, and it's a sliding door that opens slowly."],
      [:buddy, "Then the hard part is presence, not the mechanics. The treat dispenser hangs off the same signal."],
      [:them, "Just to note, the door is NOT done yet. Just planned. The door sensor is in place though."],
      [:buddy, "Got it, sensor live and the kennel door still a plan. Presence matters even more then."],
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

  let(:meta) {
    {
      them:     {},
      buddy:    { "kind" => "buddy" },
      doorbell: { "kind" => "buddy", "source" => "watch", "watch_id" => 18 },
      chip:     { "kind" => "buddy_activity", "tool_name" => "call_jil_function" },
      quick:    { "kind" => "action_chip", "buddy_action" => "suggest" },
      seed:     { "kind" => "buddy_trigger", "hidden" => true },
    }
  }

  def say(who, body, at: Time.current)
    conversation.byte_messages.create!(
      user:       user,
      direction:  who == :them ? :outbound : :inbound,
      state:      :delivered,
      body:       body,
      metadata:   meta.fetch(who),
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

      notes = described_class.settle!(conversation)

      expect(notes.size).to eq(1)
      expect(notes.first).to be_from_companion
      expect(notes.first.body).to eq("Landed on an mmWave presence sensor inside.")
      expect(idea.reload.notes.count).to eq(1)
    end

    it "writes it when the caller already knows the stretch is over" do
      lay_down(kennel)
      stub_client([{ text: "Ruled out a pressure mat on cost." }])

      expect(described_class.settle!(conversation, over: true).size).to eq(1)
    end

    it "leaves a live stretch alone" do
      lay_down(kennel)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_empty
      expect(idea.reload.notes).to be_empty
    end

    it "does not treat one unrelated question mid-thought as moving on" do
      lay_down(kennel + elsewhere.first(2))
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_empty
    end

    # The case that killed the first cut of this, which called a stretch over
    # after six quiet minutes: somebody picking a thought back up between other
    # things all day would have had every message look like the end of it.
    it "doesn't care how long they take between messages" do
      base = 3.days.ago
      kennel.each_with_index { |(who, body), i| say(who, body, at: base + (i * 5).hours) }
      conversation.update!(last_message_at: conversation.byte_messages.maximum(:created_at))
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_empty
      expect(idea.reload.notes).to be_empty
    end

    it "hands the model the idea as it stands and the conversation" do
      lay_down(kennel + elsewhere)
      fake = stub_client([{ text: "note" }])

      described_class.settle!(conversation)

      sent = fake.calls.first.input.first[:content]
      expect(sent).to include(idea.content)
      expect(sent).to include("the door is NOT done yet")
      expect(sent).to include("Them:", "Byte:")
    end

    it "writes nothing when the stretch added nothing worth keeping" do
      lay_down(kennel + elsewhere)
      stub_client([{ text: described_class::NOTHING }])

      expect(described_class.settle!(conversation)).to be_empty
      expect(idea.reload.notes).to be_empty
    end

    it "writes nothing when the model call fails" do
      lay_down(kennel + elsewhere)
      stub_client([{ error: "rate limited" }])

      expect(described_class.settle!(conversation)).to be_empty
      expect(idea.reload.notes).to be_empty
    end

    it "stays out of the way when the turn already wrote the note itself" do
      lay_down(kennel + elsewhere)
      idea.notes.create!(body: "Presence sensor it is.", source: :companion)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_empty
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

      expect(described_class.settle!(conversation)).to be_empty
    end

    it "leaves an idea alone once it's been closed out" do
      lay_down(kennel + elsewhere)
      idea.update!(status: :done)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_empty
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

    # Counted, a run of these partway through would shove most of the exchange
    # out of the window and a real conversation would read as a passing mention.
    it "doesn't let watches, chips and hidden seeds take up room in the window" do
      noise = [
        %i[doorbell chip quick seed doorbell chip],
        %i[quick seed doorbell chip quick seed],
      ].flatten.map { |kind| [kind, "🔔 Someone's at the door"] }
      lay_down(kennel + noise + elsewhere)
      stub_client([{ text: "Landed on presence." }])

      expect(described_class.settle!(conversation).size).to eq(1)
    end
  end

  # People don't think about one thing for half an hour. The kennel reminds them
  # of the greenhouse, they weave between the two, and both get further along.
  describe "two ideas at once" do
    let!(:greenhouse) {
      BuddyMemory.create!(
      kind:     :stash,
        user:     user,
        category: :home,
        status:   :active,
        summary:  "Greenhouse propagation shelf",
        content:     "propagation shelf in the greenhouse with a heat mat and grow lights on a timer",
      )
    }

    # Interleaved the way a tangent actually goes, rather than one subject
    # finishing before the other starts.
    let(:woven) {
      [
        [:them, "What would be the best ways to detect if Whisper's in the kennel or not?"],
        [:buddy, "A pressure mat inside, an IR beam across the opening, or a sensor at the kennel mouth."],
        [:them, "Oh - that reminds me, the propagation shelf in the greenhouse needs grow lights sorting."],
        [:buddy, "The greenhouse shelf? Grow lights on a timer would be the simple version of that."],
        [:them, "Back to the kennel - a beam is just a toggle, and Whisper pokes her head in constantly."],
        [:buddy, "Too binary, agreed. An mmWave presence sensor inside the kennel is the shape of it."],
        [:them, "And the kennel door sensor is already in, the sliding door itself is not."],
        [:buddy, "So the kennel logic hangs off presence, and the treat dispenser rides the same signal."],
        [:them, "For the greenhouse, does the heat mat want to be on the same timer as the grow lights?"],
        [:buddy, "Separate. The heat mat wants a thermostat, the grow lights want a clock."],
        [:them, "Right, and the greenhouse propagation shelf can wait until the grow lights arrive."],
        [:buddy, "Fine to park the greenhouse shelf there. The heat mat is the only bit with a lead time."],
      ]
    }

    it "settles both, each with its own note" do
      lay_down(woven + elsewhere)
      stub_client([
        { text: "Presence sensor inside; door still only planned." },
        { text: "Heat mat on a thermostat, grow lights on a clock." },
      ])

      notes = described_class.settle!(conversation)

      expect(notes.map(&:buddy_memory_id)).to contain_exactly(idea.id, greenhouse.id)
      expect(idea.reload.notes.map(&:body)).to eq(["Presence sensor inside; door still only planned."])
      expect(greenhouse.reload.notes.map(&:body)).to eq(["Heat mat on a thermostat, grow lights on a clock."])
    end

    # Asked one idea at a time, a tangent reads as an ending, and the two take
    # turns declaring each other over — chopping a live conversation into notes
    # about where it had got to halfway.
    it "does not treat a tangent onto the other as having moved on from either" do
      lay_down(woven)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(conversation)).to be_empty
      expect(idea.reload.notes).to be_empty
      expect(greenhouse.reload.notes).to be_empty
    end

    it "tells each note-writer what the other thread was, so it isn't folded in" do
      lay_down(woven + elsewhere)
      fake = stub_client([{ text: "note" }, { text: "note" }])

      described_class.settle!(conversation)

      briefs = fake.calls.map { |call| call.input.first[:content] }
      expect(briefs.first).to include(idea.content).and include("NOT YOURS", greenhouse.summary)
      expect(briefs.last).to include(greenhouse.content).and include("NOT YOURS", idea.summary)
    end

    it "still writes the other one when a note fails to come back for the first" do
      lay_down(woven + elsewhere)
      stub_client([{ error: "rate limited" }, { text: "Heat mat on a thermostat." }])

      notes = described_class.settle!(conversation)

      expect(notes.map(&:buddy_memory_id)).to eq([greenhouse.id])
    end
  end

  # Held ideas share vocabulary all the time, and a note on a thread that was
  # never discussed gets read back months later as a thing that was decided.
  describe "an idea that only looks like the subject" do
    let!(:garage) {
      BuddyMemory.create!(
      kind:     :stash,
        user:     user,
        category: :home,
        status:   :active,
        summary:  "Garage door sensor upgrade",
        content:     "upgrade the garage door sensor to report open and closed properly, plus presence inside",
      )
    }

    it "keeps the real subject and leaves the overlapping one alone" do
      lay_down(kennel + elsewhere)
      fake = stub_client([{ text: "Presence sensor inside." }])

      notes = described_class.settle!(conversation)

      expect(notes.map(&:buddy_memory_id)).to eq([idea.id])
      expect(garage.reload.notes).to be_empty
      expect(fake.calls.size).to eq(1)
    end
  end
end
