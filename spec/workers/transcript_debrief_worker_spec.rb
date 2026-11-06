require "rails_helper"

# The read of how the conversation went, and the chip that says it is
# happening. Third of the three passes a recording goes through, and keyed
# apart from the other two - one chip over all of them would say the work had
# finished while two thirds of it ran.
RSpec.describe TranscriptDebriefWorker do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }
  let(:transcript) {
    job.transcripts.create!(
      title: "Hiring manager",
      turns: [{ "raw" => "Unknown", "speaker" => "Me", "text" => "Thanks for the time." }],
    )
  }

  def chip
    BackgroundProcess.live_find(user, Transcripts::Debrief.key_for(transcript))
  end

  it "raises its own chip and takes it down however the pass went" do
    seen = []
    allow(Transcripts::Debrief).to receive(:call) { |_transcript, **_moved, &progress|
      seen << [chip&.current, chip&.total]
      progress.call(1, 1)
      seen << [chip&.current, chip&.total]
      Transcripts::Debrief::Result.new(ok: true, notes: 4)
    }

    described_class.new.perform(transcript.id)

    expect(seen).to eq([[nil, nil], [1, 1]])
    expect(chip).to be_nil
  end

  it "asks for a second reading only when it was pressed for" do
    allow(Transcripts::Debrief).to receive(:call)
      .and_return(Transcripts::Debrief::Result.new(ok: false, notes: 0, error: :done))

    described_class.new.perform(transcript.id, true)

    expect(Transcripts::Debrief).to have_received(:call).with(transcript, again: true)
  end

  # The two passes that run beside each other both ask whether the recording is
  # finished, because neither can tell which of them is last.
  it "tells him it can be read when it was the last pass over it" do
    user.byte_conversations.create!(name: "Byte", mode: :buddy)
    transcript.update!(tidied_at: Time.current, cleaned_at: Time.current)
    allow(Transcripts::Debrief).to receive(:call) { |held, **_moved|
      held.update!(debriefed_at: Time.current, debrief: { "read" => "It went well." })
      Transcripts::Debrief::Result.new(ok: true, notes: 1)
    }

    described_class.new.perform(transcript.id)
    said = ByteConversation.for_self_initiated(user).byte_messages.order(:id).last

    expect(said.metadata["source"]).to eq("transcript_ready")
    expect(said.body).to include(transcript.reading_url)
  end

  it "does nothing at all for a transcript that has since been deleted" do
    id = transcript.id
    transcript.destroy!

    expect { described_class.new.perform(id) }.not_to raise_error
  end
end
