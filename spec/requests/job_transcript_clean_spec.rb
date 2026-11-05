require "rails_helper"

# Reading a recording instead of decoding it.
#
# Both versions of the conversation are on the row - what was said, and the
# same thing with the noise of speech taken out - and the page shows one of
# them. Which one is in the URL, so a read can be linked and nothing about the
# recording has to change to look at it the other way.
RSpec.describe "Job transcript clean", type: :request do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }
  let(:transcript) {
    job.transcripts.create!(
      title:      "Hiring manager",
      speakers:   { "Me" => { "name" => "Rocco", "me" => true } },
      cleaned_at: Time.current,
      turns:      [
        {
          "raw"     => "Unknown",
          "speaker" => "Me",
          "text"    => "Um, my, my biggest thing is, is internal tools, like, tools.",
          "clean"   => "My biggest thing is internal tools.",
        },
        { "raw" => "Unknown", "speaker" => "Me", "text" => "It is faster than it sounds." },
        { "raw" => "Unknown", "speaker" => "Me", "text" => "Ooh. Um...", "clean" => "" },
      ],
    )
  }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post(login_path, params: { user: { username: user.username, password: "password123" } })
    allow(TranscriptCleanWorker).to receive(:perform_async)
  end

  it "starts another cleaning" do
    post(clean_interview_transcript_path(job, transcript))

    expect(TranscriptCleanWorker).to have_received(:perform_async).with(transcript.id, true)
    expect(response).to redirect_to(interview_transcript_path(job, transcript))
  end

  # The lookup goes through the current user's applications, so an id from
  # somebody else's board never resolves and nothing is paid for on it.
  it "starts nothing for a transcript on somebody else's application" do
    other = create(:user).job_applications.create!(company: "Elsewhere")
    theirs = other.transcripts.create!(turns: [{ "speaker" => "Me", "text" => "Hello." }])

    post(clean_interview_transcript_path(other, theirs))

    expect(TranscriptCleanWorker).not_to have_received(:perform_async)
    expect(response).to have_http_status(:redirect)
  end

  # The default, because the page is where the turns get corrected and all of
  # that is work on the words that were said.
  it "opens on what was said, with the cleaned read offered" do
    get(interview_transcript_path(job, transcript))

    expect(response.body).to include("Um, my, my biggest thing")
    expect(response.body).not_to include("My biggest thing is internal tools.")
    expect(response.body).to include("Read it cleaned up")
  end

  it "reads the cleaned version when it is asked for, and keeps what was said in reach" do
    get(interview_transcript_path(job, transcript, read: :clean))

    expect(response.body).to include("My biggest thing is internal tools.")
    expect(response.body).to include("As he said it: Um, my, my biggest thing")
    expect(response.body).to include("Read it as said")
  end

  # A turn the cleaning left alone has no cleaned version stored, and the
  # readable version falls back to what was said rather than showing a gap.
  it "falls back to what was said on a turn that needed no cleaning" do
    get(interview_transcript_path(job, transcript, read: :clean))

    expect(response.body).to include("It is faster than it sounds.")
  end

  # A turn that was nothing but noise is not in a version meant to be read.
  it "leaves a turn that cleaned away to nothing out of the readable version" do
    get(interview_transcript_path(job, transcript, read: :clean))
    expect(response.body).not_to include("Ooh. Um...")

    get(interview_transcript_path(job, transcript))
    expect(response.body).to include("Ooh. Um...")
  end

  # Nothing to switch to until a cleaning has actually been over it, so the
  # link is absent rather than offering a read that would be the spoken one
  # under a different name.
  it "offers no cleaned read on a recording that has not been cleaned" do
    transcript.update!(cleaned_at: nil)

    get(interview_transcript_path(job, transcript, read: :clean))

    expect(response.body).not_to include("Read it cleaned up")
    expect(response.body).to include("Um, my, my biggest thing")
  end

  # The JSON the local job hunter reads carries both, because its two callers
  # want different ones: an answer going into the bank is the readable version,
  # and a note about how the answer was delivered is the spoken one.
  it "sends both versions to the local reader" do
    get(interview_transcript_path(job, transcript, format: :json))
    turns = response.parsed_body["turns"]

    expect(turns.first["text"]).to start_with("Um, my, my biggest thing")
    expect(turns.first["clean"]).to eq("My biggest thing is internal tools.")
    expect(turns.second).not_to have_key("clean")
  end
end
