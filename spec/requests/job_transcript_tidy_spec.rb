require "rails_helper"

# Going back over the words of a recording that is already on the board. The
# pass runs by itself when a file lands, and this is the press for the two
# times that is not enough: it read the words before who was talking had been
# corrected by hand, or it did not know the terms and wrote the same
# mishearing in thirty places.
RSpec.describe "Job transcript tidy", type: :request do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }
  let(:transcript) {
    job.transcripts.create!(
      title:    "Hiring manager",
      speakers: { "Me" => { "name" => "Rocco", "me" => true } },
      turns:    [
        {
          "raw"     => "Unknown",
          "speaker" => "Me",
          "text"    => "I'm hand coding everything now.",
          "heard"   => "I'm hand coating everything now.",
        },
        { "raw" => "Unknown", "speaker" => "Me", "text" => "It is faster than it sounds." },
      ],
    )
  }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post(login_path, params: { user: { username: user.username, password: "password123" } })
    allow(TranscriptTidyWorker).to receive(:perform_async)
  end

  it "starts another pass and says so" do
    post(tidy_interview_transcript_path(job, transcript))

    expect(TranscriptTidyWorker).to have_received(:perform_async).with(transcript.id, true)
    expect(response).to redirect_to(interview_transcript_path(job, transcript))
    expect(flash[:notice]).to include("Going back over the words")
  end

  # The lookup goes through the current user's applications, so an id from
  # somebody else's board never resolves and nothing is paid for on it.
  it "starts nothing for a transcript on somebody else's application" do
    other = create(:user).job_applications.create!(company: "Elsewhere")
    theirs = other.transcripts.create!(turns: [{ "speaker" => "Me", "text" => "Hello." }])

    post(tidy_interview_transcript_path(other, theirs))

    expect(TranscriptTidyWorker).not_to have_received(:perform_async)
    expect(response).to have_http_status(:redirect)
  end

  describe "the page afterwards" do
    it "keeps what the recorder wrote on a turn whose words were put right" do
      transcript.update!(tidied_at: Time.current)

      get(interview_transcript_path(job, transcript))

      expect(response.body).to include("I&#39;m hand coding everything now.")
      expect(response.body).to include("As the recorder heard it: I&#39;m hand coating")
      expect(response.body).to include("1 turn put right")
    end

    it "says the words were checked when the pass found nothing to do" do
      transcript.update!(tidied_at: Time.current, turns: [
        { "raw" => "Unknown", "speaker" => "Me", "text" => "It is faster than it sounds." },
      ])

      get(interview_transcript_path(job, transcript))

      expect(response.body).to include("words checked")
      expect(response.body).not_to include("As the recorder heard it")
    end

    it "says nothing about it on a recording nobody has been over" do
      get(interview_transcript_path(job, transcript))

      expect(response.body).not_to include("words checked")
      expect(response.body).not_to include("put right")
    end
  end
end
