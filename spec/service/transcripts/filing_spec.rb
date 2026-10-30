require "rails_helper"

# Which interview a recording was, worked out from the clock after the fact.
# Nothing arms off the calendar - the recorder starts when the microphone goes
# hot and knows nothing about the board - so this is the only place a booking
# is consulted, and it is only ever asked which call already happened.
RSpec.describe Transcripts::Filing do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }
  let(:other) { user.job_applications.create!(company: "Brightwheel") }

  def booking(application, at, minutes: 30, tag: :interview)
    application.notes.create!(tag: tag, occurred_at: at, duration_minutes: minutes)
  end

  # Minutes of talking, so the recording has a span to overlap with. One turn a
  # minute, which is all `spoken_minutes` reads.
  def recording!(at, minutes: 30)
    user.job_transcripts.create!(
      occurred_at: at,
      speakers:    { "Me" => { "name" => "Rocco", "me" => true } },
      turns:       [
        { "speaker" => "Me", "at" => 0.0, "to" => 20.0, "text" => "Hello." },
        {
          "speaker" => "Me",
          "at"      => (minutes * 60).to_f,
          "to"      => (minutes * 60).to_f + 10,
          "text"    => "Thanks.",
        },
      ],
    )
  end

  describe "one answer" do
    it "files a recording that started when the interview was booked" do
      note = booking(job, Time.zone.parse("2026-10-29 14:00"))
      transcript = recording!(Time.zone.parse("2026-10-29 14:02"))

      expect(described_class.call(transcript)).to eq(note)
      expect(transcript.reload.job_application).to eq(job)
      expect(transcript.job_note).to eq(note)
    end

    # The booking only knows when the call was MEANT to happen; the recording
    # knows when it did.
    it "keeps the recording's own clock rather than the booking's" do
      booking(job, Time.zone.parse("2026-10-29 14:00"))
      started = Time.zone.parse("2026-10-29 14:11")
      transcript = recording!(started)

      described_class.call(transcript)

      expect(transcript.reload.occurred_at).to eq(started)
    end

    # A nearest-start rule reads this as belonging to whatever was booked for
    # half past, which is why the overlap is tested first.
    it "files an hour-long round he joined twenty minutes late" do
      note = booking(job, Time.zone.parse("2026-10-29 14:00"), minutes: 60)
      transcript = recording!(Time.zone.parse("2026-10-29 14:20"), minutes: 40)

      expect(described_class.call(transcript)).to eq(note)
    end

    it "files a recording that started a few minutes early" do
      note = booking(job, Time.zone.parse("2026-10-29 14:00"))

      expect(described_class.call(recording!(Time.zone.parse("2026-10-29 13:52")))).to eq(note)
    end
  end

  describe "no answer worth acting on" do
    # The expensive mistake: a debrief filed on the wrong company reads as a
    # conversation he never had, and nothing on the page would say otherwise.
    it "leaves a recording alone when two interviews could both be it" do
      booking(job, Time.zone.parse("2026-10-29 14:00"), minutes: 60)
      booking(other, Time.zone.parse("2026-10-29 14:30"), minutes: 60)
      transcript = recording!(Time.zone.parse("2026-10-29 14:05"), minutes: 55)

      expect(described_class.call(transcript)).to be_nil
      expect(transcript.reload).not_to be_filed
    end

    # Unfiled, but not unanswerable: the index asks with these.
    it "still names both of them as candidates" do
      booking(job, Time.zone.parse("2026-10-29 14:00"), minutes: 60)
      booking(other, Time.zone.parse("2026-10-29 14:30"), minutes: 60)
      transcript = recording!(Time.zone.parse("2026-10-29 14:05"), minutes: 55)

      found = described_class.candidates(transcript).map { |note| note.job_application.company }

      expect(found).to contain_exactly("Podium", "Brightwheel")
    end

    it "leaves a recording alone when nothing was booked anywhere near it" do
      booking(job, Time.zone.parse("2026-10-29 09:00"))

      expect(described_class.call(recording!(Time.zone.parse("2026-10-29 14:00")))).to be_nil
    end

    # A mail is not a conversation. Nothing was said out loud on an `applied`
    # row, so a recording cannot be it.
    it "ignores beats that are not a conversation" do
      booking(job, Time.zone.parse("2026-10-29 14:00"), tag: :applied)

      expect(described_class.call(recording!(Time.zone.parse("2026-10-29 14:00")))).to be_nil
    end

    it "never overrules a recording somebody already filed" do
      booking(job, Time.zone.parse("2026-10-29 14:00"))
      transcript = recording!(Time.zone.parse("2026-10-29 14:00"))
      transcript.file!(other)

      expect(described_class.call(transcript)).to be_nil
      expect(transcript.reload.job_application).to eq(other)
    end

    it "never reaches a booking on somebody else's board" do
      theirs = create(:user).job_applications.create!(company: "Elsewhere")
      theirs.notes.create!(tag: :interview, occurred_at: Time.zone.parse("2026-10-29 14:00"))

      expect(described_class.call(recording!(Time.zone.parse("2026-10-29 14:00")))).to be_nil
    end
  end
end
