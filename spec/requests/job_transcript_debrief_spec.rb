require "rails_helper"

# Reading a recording back for how it went. It runs by itself once the words
# have been gone over, and the press is for after he has corrected something
# the passes got wrong - who was talking, or a word.
RSpec.describe "Job transcript debrief", type: :request do
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
          "at"      => 240.0,
          "text"    => "We had four inboxes and I pulled them into one place.",
        },
        { "raw" => "Unknown", "speaker" => "Me", "text" => "It is faster than it sounds." },
      ],
    )
  }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post(login_path, params: { user: { username: user.username, password: "password123" } })
    allow(TranscriptDebriefWorker).to receive(:perform_async)
  end

  it "starts another reading and says so" do
    post(debrief_interview_transcript_path(job, transcript))

    expect(TranscriptDebriefWorker).to have_received(:perform_async).with(transcript.id, true)
    expect(response).to redirect_to(interview_transcript_path(job, transcript))
    expect(flash[:notice]).to include("Reading it back")
  end

  it "starts nothing for a transcript on somebody else's application" do
    other = create(:user).job_applications.create!(company: "Elsewhere")
    theirs = other.transcripts.create!(turns: [{ "speaker" => "Me", "text" => "Hello." }])

    post(debrief_interview_transcript_path(other, theirs))

    expect(TranscriptDebriefWorker).not_to have_received(:perform_async)
    expect(response).to have_http_status(:redirect)
  end

  describe "the page" do
    it "shows the read, the quote it is about, and the sentence to say instead" do
      transcript.update!(debriefed_at: Time.current, debrief: {
        "read"      => "You never answered the one about scale.",
        "cost"      => [{
          "turn"    => 1,
          "what"    => "No number anywhere in the mail story.",
          "instead" => "Four inboxes, about twenty thousand a day.",
        }],
        "strongest" => [{ "turn" => 2, "why" => "Said it in one line." }],
        "missed"    => [{ "what" => "Never asked what happens next.", "where" => "at the end" }],
        "next"      => ["Carry one number for every story."],
      })

      get(interview_transcript_path(job, transcript))

      expect(response.body).to include("You never answered the one about scale.")
      expect(response.body).to include("No number anywhere in the mail story.")
      expect(response.body).to include("Four inboxes, about twenty thousand a day.")
      expect(response.body).to include("We had four inboxes")
      expect(response.body).to include("Never asked what happens next.")
      expect(response.body).to include("Carry one number for every story.")
      expect(response.body).to include("Read it again")
      # The note links down into the turn it is about.
      expect(response.body).to include("href=\"#t1\"")
      expect(response.body).to include("id=\"t1\"")
    end

    it "says nothing about how it went on a recording nobody has read" do
      get(interview_transcript_path(job, transcript))

      expect(response.body).not_to include("How it went")
      expect(response.body).to include("How did I do")
    end

    # Nothing can be said about how he did until somebody is marked as him, so
    # the page asks for that instead of offering a reading it would refuse.
    it "asks who he is first when no turn has been placed on him" do
      transcript.update!(speakers: {})

      get(interview_transcript_path(job, transcript))

      expect(response.body).to include("Tick which speaker is you")
    end
  end
end
