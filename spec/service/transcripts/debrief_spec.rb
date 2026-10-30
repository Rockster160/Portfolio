require "rails_helper"

# The read of a recorded interview: how it went, what cost him, and the
# sentence to say instead. The thing that goes wrong with feedback is not a
# rewrite - it is generosity, and a note about an interview nobody had. So
# every judgment has to name one of HIS turns, and the ones that do not are
# dropped here rather than trusted not to arrive.
RSpec.describe Transcripts::Debrief do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }

  def asked = (@asked ||= [])

  def model_says(text)
    allow_any_instance_of(Buddy::GPT::Client).to receive(:stream) { |_client, args|
      asked << args[:instructions].to_s
      {
        ok:    true,
        text:  text,
        model: "gpt-5.4",
        usage: FakeBuddyClient::DEFAULT_USAGE,
      }
    }
  end

  def said(**found)
    {
      read:      "You answered the stack question and never answered the one about scale.",
      strongest: [],
      cost:      [],
      missed:    [],
      next:      [],
    }.merge(found).to_json
  end

  # Six turns is the floor, so the shortest transcript here is one that can be
  # judged at all. Odd turns are his, which is the shape of a conversation.
  def transcript!(*texts, mine: true)
    rows = texts.any? ? texts : Array.new(6) { |at| "Turn number #{at}, with enough said in it." }
    job.transcripts.create!(
      title:    "Hiring manager",
      speakers: {
        "Me"   => { "name" => "Rocco", "me" => mine },
        "Them" => { "name" => "Dana" },
      },
      turns:    rows.each_with_index.map { |text, index|
        {
          "raw"     => "Unknown",
          "speaker" => index.odd? ? "Me" : "Them",
          "at"      => index * 60.0,
          "to"      => (index * 60.0) + 50,
          "text"    => text,
        }
      },
    )
  end

  describe "a conversation it can read" do
    subject(:transcript) { transcript! }

    it "writes the read, the notes, and when it was read" do
      note = { turn: 2, what: "The scale question went by.", instead: "Four inboxes, 20k a day." }
      model_says(said(cost: [note], next: ["Ask what the on-call rotation looks like."]))

      result = described_class.call(transcript)

      expect(result.ok).to be(true)
      expect(result.notes).to eq(2)
      expect(transcript.reload.debrief["read"]).to start_with("You answered the stack question")
      expect(transcript.debrief["cost"].first["instead"]).to eq("Four inboxes, 20k a day.")
      expect(transcript.debrief["next"]).to eq(["Ask what the on-call rotation looks like."])
      expect(transcript.debriefed_at).to be_present
      expect(transcript).to be_debriefed
    end

    it "is read once by itself and after that only when it is asked for" do
      model_says(said)

      expect { described_class.call(transcript) }
        .to change { transcript.reload.debriefed_at }.from(nil)

      expect(described_class.call(transcript).error).to eq(:done)
      expect(described_class.call(transcript, again: true).ok).to be(true)
    end
  end

  # The guard, and the reason a note carries a turn number at all: a judgment
  # that cannot be traced back to something he said is a judgment about a
  # conversation that has been partly imagined.
  describe "a note that points at nothing of his" do
    subject(:transcript) { transcript! }

    it "drops a note hung on the interviewer's own line" do
      model_says(said(cost: [{ turn: 1, what: "Rambled here.", instead: "Say it in a line." }]))

      expect(described_class.call(transcript).notes).to eq(0)
      expect(transcript.reload.debrief["cost"]).to eq([])
    end

    it "drops a note hung on a turn that is not in the conversation" do
      model_says(said(strongest: [{ turn: 94, why: "Strong close." }]))

      expect(described_class.call(transcript).notes).to eq(0)
      expect(transcript.reload.debrief["strongest"]).to eq([])
    end

    it "keeps the read even when every note was thrown away" do
      model_says(said(cost: [{ turn: 1, what: "Not his line.", instead: "No." }]))

      expect(described_class.call(transcript).ok).to be(true)
      expect(transcript.reload.debrief["read"]).to be_present
    end
  end

  # Praise is the failure mode here, so the ceiling on it is mechanical rather
  # than a sentence in the prompt asking nicely.
  it "keeps at most three of the things that landed" do
    rows = Array.new(12) { |at| "Turn #{at}, said at some length." }
    landed = [2, 4, 6, 8, 10].map { |turn| { turn: turn, why: "Good answer at #{turn}." } }
    transcript = transcript!(*rows)
    model_says(said(strongest: landed))

    described_class.call(transcript)

    expect(transcript.reload.debrief["strongest"].length).to eq(3)
  end

  describe "a recording nothing can be said about" do
    it "refuses, and pays for nothing, when nobody is marked as him" do
      transcript = transcript!(mine: false)
      model_says(said)

      result = described_class.call(transcript)

      expect(result.error).to eq(:unplaced)
      expect(transcript.reload.debriefed_at).to be_nil
      expect(asked).to be_empty
    end

    it "refuses, and pays for nothing, for a conversation too short to judge" do
      transcript = transcript!("Hello.", "Hi there.")
      model_says(said)

      expect(described_class.call(transcript).error).to eq(:thin)
      expect(asked).to be_empty
    end

    it "leaves the row alone when the reply cannot be read" do
      transcript = transcript!
      model_says("I could not read that transcript.")

      result = described_class.call(transcript)

      expect(result.error).to eq(:unreadable)
      expect(transcript.reload.debriefed_at).to be_nil
    end
  end

  describe "the prompt" do
    it "numbers every turn, marks his side, and says what the conversation was" do
      rest = Array.new(4, "More.")
      transcript = transcript!("What have you built?", "A mail consolidation.", *rest)
      model_says(said)

      described_class.call(transcript)

      expect(asked.first).to include("1. [Dana] What have you built?")
      expect(asked.first).to include("2. [ME] A mail consolidation.")
      expect(asked.first).to include("The company interviewing them is Podium.")
    end

    # An hour of talking fits. What goes when it does not is their longest
    # stretch - the company being described - because it is the one part of an
    # interview that is not evidence about how he did.
    it "trims their longest turn to fit and never touches his" do
      wall = "So what we do here is a long explanation. " * 1_200
      mine = "My answer, which is the thing being judged. " * 20
      transcript = transcript!("Short question.", mine, wall, "And?", "Yes.", "Thanks.")
      model_says(said)

      described_class.call(transcript)

      expect(asked.first).to include(mine.strip)
      expect(asked.first).not_to include(wall.strip)
      expect(asked.first).to include("…")
    end
  end
end
