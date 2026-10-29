require "rails_helper"

# The pass that reads a dropped recording, and the chip that says it is
# happening. A minute of silence with nothing on screen is indistinguishable
# from a worker that died, so the chip is part of the job and not decoration.
RSpec.describe TranscriptSpeakersWorker do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Bluestaq", role: "Principal Engineer") }
  let(:transcript) {
    job.transcripts.create!(
      title: "Hiring manager",
      turns: [{ "raw" => "Unknown", "speaker" => "Unknown", "text" => "Thanks for the time." }],
    )
  }

  def chip
    BackgroundProcess.live_find(user, Transcripts::Speakers.key_for(transcript))
  end

  # The pass over the words runs straight after this one, and a queue is inline
  # here - left alone it would be a model call on every example in this file.
  before { allow(TranscriptTidyWorker).to receive(:perform_async) }

  it "raises a chip before the first call and moves it as the calls land" do
    seen = []
    allow(Transcripts::Speakers).to receive(:call) { |_transcript, &progress|
      seen << [chip&.current, chip&.total]
      progress.call(1, 3)
      seen << [chip&.current, chip&.total]
      Transcripts::Speakers::Result.new(ok: true, placed: 2, unplaced: 0)
    }

    described_class.new.perform(transcript.id)

    expect(seen).to eq([[nil, nil], [1, 3]])
  end

  it "takes the chip down when the pass is over, however it went" do
    allow(Transcripts::Speakers).to receive(:call)
      .and_return(Transcripts::Speakers::Result.new(ok: false, error: :unreadable))

    described_class.new.perform(transcript.id)

    expect(chip).to be_nil
  end

  # The two passes run one after the other because the second one reads the
  # turns the first one writes.
  it "hands the recording on to the pass over the words" do
    allow(Transcripts::Speakers).to receive(:call)
      .and_return(Transcripts::Speakers::Result.new(ok: true, placed: 1, unplaced: 0))

    described_class.new.perform(transcript.id)

    expect(TranscriptTidyWorker).to have_received(:perform_async).with(transcript.id)
  end

  it "does nothing at all for a transcript that has since been deleted" do
    id = transcript.id
    transcript.destroy!

    expect { described_class.new.perform(id) }.not_to raise_error
  end
end
