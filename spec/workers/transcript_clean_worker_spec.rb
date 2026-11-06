require "rails_helper"

# The readable version, and the chip that says it is being written. Runs beside
# the read of how it went rather than after it, so it is the other half of the
# pair that has to work out between them which one finished last.
RSpec.describe TranscriptCleanWorker do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }
  let(:transcript) {
    job.transcripts.create!(
      title: "Hiring manager",
      turns: [{ "raw" => "Unknown", "speaker" => "Me", "text" => "Um, so, it runs itself." }],
    )
  }

  def chip
    BackgroundProcess.live_find(user, Transcripts::Clean.key_for(transcript))
  end

  it "raises its own chip and takes it down however the pass went" do
    allow(Transcripts::Clean).to receive(:call) { |_transcript, **_moved, &progress|
      progress.call(1, 1)
      Transcripts::Clean::Result.new(ok: true, cleaned: 1, turns: 1)
    }

    described_class.new.perform(transcript.id)

    expect(chip).to be_nil
  end

  it "tells him it can be read when it was the last pass over it" do
    user.byte_conversations.create!(name: "Byte", mode: :buddy)
    transcript.update!(
      tidied_at:    Time.current,
      debriefed_at: Time.current,
      debrief:      { "read" => "It went well." },
    )
    allow(Transcripts::Clean).to receive(:call) { |held, **_moved|
      held.update!(cleaned_at: Time.current)
      Transcripts::Clean::Result.new(ok: true, cleaned: 1, turns: 1)
    }

    described_class.new.perform(transcript.id)
    said = ByteConversation.for_self_initiated(user).byte_messages.order(:id).last

    expect(said.metadata["source"]).to eq("transcript_ready")
    expect(said.body).to include(transcript.reading_url)
  end

  # A recording the cleaning could make nothing of is not ready to read, so
  # nothing is said about it - the stamp is what the message is read off.
  it "says nothing when the pass could not write anything" do
    user.byte_conversations.create!(name: "Byte", mode: :buddy)
    transcript.update!(tidied_at: Time.current, debriefed_at: Time.current)
    allow(Transcripts::Clean).to receive(:call)
      .and_return(Transcripts::Clean::Result.new(ok: false, cleaned: 0, turns: 0, error: :unusable))

    described_class.new.perform(transcript.id)

    expect(transcript.reload.announced_at).to be_nil
  end

  it "does nothing at all for a transcript that has since been deleted" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
