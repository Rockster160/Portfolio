require "rails_helper"

# The pass over the words, and the chip that says it is happening. It is the
# second of the two a recording goes through, and the two are told apart by
# their keys - a shared chip would take the first one's down and say the work
# had finished while the rest of it ran.
RSpec.describe TranscriptTidyWorker do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }
  let(:transcript) {
    job.transcripts.create!(
      title: "Hiring manager",
      turns: [{ "raw" => "Unknown", "speaker" => "Unknown", "text" => "Thanks for the time." }],
    )
  }

  def chip
    BackgroundProcess.live_find(user, Transcripts::Tidy.key_for(transcript))
  end

  # The read of how it went runs straight after this one, and a queue is inline
  # here - left alone it would be a model call on every example in this file.
  before { allow(TranscriptDebriefWorker).to receive(:perform_async) }

  it "raises its own chip and moves it as the calls land" do
    seen = []
    allow(Transcripts::Tidy).to receive(:call) { |_transcript, **_moved, &progress|
      seen << [chip&.current, chip&.total]
      progress.call(1, 2)
      seen << [chip&.current, chip&.total]
      Transcripts::Tidy::Result.new(ok: true, mended: 3, turns: 2)
    }

    described_class.new.perform(transcript.id)

    expect(seen).to eq([[nil, nil], [1, 2]])
    expect(chip).to be_nil
  end

  it "asks for a second reading only when it was pressed for" do
    allow(Transcripts::Tidy).to receive(:call)
      .and_return(Transcripts::Tidy::Result.new(ok: true, mended: 0, turns: 0))

    described_class.new.perform(transcript.id, true)

    expect(Transcripts::Tidy).to have_received(:call).with(transcript, again: true)
  end

  # The three passes run one after the other because each reads what the one
  # before it wrote. A second pass over the words carries through as a second
  # reading of how it went: the words that reading would be made of just
  # changed.
  it "hands the recording on to the read of how it went" do
    allow(Transcripts::Tidy).to receive(:call)
      .and_return(Transcripts::Tidy::Result.new(ok: true, mended: 1, turns: 1))

    described_class.new.perform(transcript.id)
    described_class.new.perform(transcript.id, true)

    expect(TranscriptDebriefWorker).to have_received(:perform_async).with(transcript.id, false)
    expect(TranscriptDebriefWorker).to have_received(:perform_async).with(transcript.id, true)
  end

  it "does nothing at all for a transcript that has since been deleted" do
    id = transcript.id
    transcript.destroy!

    expect { described_class.new.perform(id) }.not_to raise_error
  end
end
