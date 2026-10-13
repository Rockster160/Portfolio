require "rails_helper"

RSpec.describe JobTranscript do
  let(:user) { create(:user) }
  let(:job) { user.job_applications.create!(company: "Bluestaq") }
  let(:text) {
    <<~VTT
      00:00:01 --> 00:00:04
      Speaker 1: How do you handle disagreeing with a teammate?

      00:00:05 --> 00:00:09
      Speaker 2: I would rather have the argument early.

      00:00:40 --> 00:00:44
      Unknown: That is a fair answer.
    VTT
  }

  def ingested(title: nil)
    job.transcripts.new(title: title).ingest!(StringIO.new(text), filename: "bluestaq-hm.txt")
  end

  describe "taking a file in" do
    it "reads the conversation out of it" do
      transcript = ingested

      expect(transcript.turns.length).to eq(3)
      expect(transcript.labels).to eq(["Speaker 1", "Speaker 2", "Unknown"])
    end

    # The file is the record and the title is how it is found again. A name
    # taken off the filename beats `Transcript` under three of them.
    it "names itself after the file when nothing else named it" do
      expect(ingested.title).to eq("bluestaq hm")
    end

    it "keeps a title that was given" do
      expect(ingested(title: "Hiring manager").title).to eq("Hiring manager")
    end

    # NOTHING GUESSES WHO ANYBODY IS. The recorder's own guess is `Speaker 2`,
    # and a wrong name on a quote read back months later is worse than none.
    it "leaves every speaker unnamed" do
      expect(ingested.speakers).to eq({})
    end
  end

  describe "naming the speakers" do
    it "records the name and which one is him" do
      transcript = ingested.tap(&:save!)

      transcript.rename_speakers!(
        "Speaker 1" => { "name" => "Casey Holm", "me" => "0" },
        "Speaker 2" => { "name" => "Rocco", "me" => "1" },
      )

      expect(transcript.name_for("Speaker 1")).to eq("Casey Holm")
      expect(transcript).to be_mine("Speaker 2")
      expect(transcript).not_to be_mine("Speaker 1")
    end

    it "answers with the raw label for one nobody has named" do
      expect(ingested.name_for("Speaker 3")).to eq("Speaker 3")
    end

    # Two different people land under `Unknown`, so it is never a person, and
    # ticking it would put somebody else's words on his side of the page.
    it "refuses to call the unplaced label him" do
      transcript = ingested.tap(&:save!)
      transcript.rename_speakers!("Unknown" => { "name" => "Me", "me" => "1" })

      expect(transcript).not_to be_mine("Unknown")
    end

    it "drops a row that was left blank rather than storing an empty name" do
      transcript = ingested.tap(&:save!)
      transcript.rename_speakers!("Speaker 1" => { "name" => "  ", "me" => "0" })

      expect(transcript.speakers).to eq({})
    end
  end

  describe "moving a turn onto somebody else" do
    it "changes that turn and leaves the label it arrived under alone" do
      transcript = ingested.tap(&:save!)

      expect(transcript.reassign!("2" => "Speaker 1")).to eq(1)
      expect(transcript.turns[2]["speaker"]).to eq("Speaker 1")
      expect(transcript.turns[2]["raw"]).to eq("Unknown")
    end

    # The whole page posts at once, so all 126 turns arrive saying what they
    # already said. Writing them back would be a row rewritten per read.
    it "writes nothing when nothing moved" do
      transcript = ingested.tap(&:save!)
      was = transcript.updated_at

      expect(transcript.reassign!("0" => "Speaker 1", "1" => "Speaker 2")).to eq(0)
      expect(transcript.reload.updated_at).to eq(was)
    end

    it "ignores an index that is not there" do
      transcript = ingested.tap(&:save!)

      expect(transcript.reassign!("99" => "Speaker 1")).to eq(0)
    end

    # A turn already corrected has to stay pickable, or the one option missing
    # from its own picker is the one it is set to.
    it "offers a corrected label as somewhere to move to" do
      transcript = ingested.tap(&:save!)
      transcript.reassign!("2" => "Casey Holm")

      expect(transcript.speaker_options).to include("Casey Holm")
    end
  end

  it "says how long the talking lasted" do
    expect(ingested.spoken_minutes).to eq(1)
  end
end
