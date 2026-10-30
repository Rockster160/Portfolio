require "rails_helper"

# The recorder's door, and what happens to a call it could not place.
#
# Everything the microphone hears gets recorded and the junk is thrown away
# here - that way round, because an hour of something irrelevant costs a glance
# and one press, and an interview that was never recorded cannot be got back.
RSpec.describe "Recorded calls", type: :request do
  let(:user) { User.me }
  let(:api_key) { user.api_keys.create!(name: "laptop") }
  let(:headers) { { "Authorization" => "Bearer #{api_key.key}" } }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }

  def recording(**given)
    {
      recording: {
        started_at: "2026-10-29T14:02:00-06:00",
        source:     { app: "Chrome", host: "meet.google.com" },
        segments:   [
          { who: "them", at: 0.0, to: 3.0, text: "Thanks for making the time." },
          { who: "me",   at: 3.4, to: 6.0, text: "Thanks for having me." },
        ],
      }.merge(given),
    }
  end

  def said = response.parsed_body

  before do
    allow(TranscriptSpeakersWorker).to receive(:perform_async)
    allow(TranscriptDebriefWorker).to receive(:perform_async)
  end

  describe "a call arriving off the laptop" do
    it "keeps the words and says what it did with them" do
      expect { post(transcripts_path, params: recording, headers: headers) }
        .to change(JobTranscript, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(said["filed"]).to be_nil
      expect(JobTranscript.last.turns.length).to eq(2)
    end

    it "files it on the interview the clock says it was" do
      job.notes.create!(tag: :interview, occurred_at: Time.zone.parse("2026-10-29T14:00:00-06:00"))

      post(transcripts_path, params: recording, headers: headers)

      expect(said.dig("filed", "company")).to eq("Podium")
    end

    # The recorder has no settings of its own and nothing on the laptop to
    # edit, so the one moment it is certainly talking to the board is the
    # moment it finds out what it must not record any more.
    it "hands back the sources it is not to record from" do
      user.recording_skips.create!(key: "discord.com", label: "discord.com")

      post(transcripts_path, params: recording, headers: headers)

      expect(said["skip"]).to eq(["discord.com"])
    end

    it "says so rather than saving nothing when there were no words in it" do
      post(transcripts_path, params: recording(segments: []), headers: headers)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JobTranscript.count).to eq(0)
    end

    it "takes nothing from a caller with no key" do
      post(transcripts_path, params: recording)

      expect(JobTranscript.count).to eq(0)
    end

    it "answers what it must not record when it starts up" do
      user.recording_skips.create!(key: "discord.com")

      get(skips_transcripts_path, headers: headers)

      expect(said["skip"]).to eq(["discord.com"])
    end
  end

  describe "a recording nobody has placed" do
    let!(:transcript) {
      user.job_transcripts.create!(
        occurred_at: user.parse_time("2026-10-29 14:02"),
        source:      { "app" => "Chrome", "host" => "meet.google.com" },
        speakers:    { "Me" => { "name" => "Rocco", "me" => true } },
        turns:       [{ "speaker" => "Me", "at" => 0.0, "text" => "Thanks for having me." }],
      )
    }

    before do
      user.update!(password: "password123", password_confirmation: "password123")
      post(login_path, params: { user: { username: user.username, password: "password123" } })
    end

    it "waits on the interview index, with the start of it to go on" do
      get(interviews_path)

      expect(response.body).to include("Recordings to file")
      expect(response.body).to include("Thanks for having me.")
      expect(response.body).to include("meet.google.com")
    end

    # A picker that opens on the two interviews the clock suggested asks "which
    # of these"; one that opens on the whole board asks him to go and remember.
    it "offers the interviews the clock suggested, named and dated" do
      job.notes.create!(tag: :interview, occurred_at: user.parse_time("2026-10-29 14:00"))
      other = user.job_applications.create!(company: "Brightwheel")
      other.notes.create!(tag: :recruiter_call, occurred_at: user.parse_time("2026-10-29 14:10"))

      get(interviews_path)

      expect(response.body).to include("Podium — Thursday, Oct 29 at 2:00 PM")
      expect(response.body).to include("Brightwheel — Thursday, Oct 29 at 2:10 PM")
    end

    # Filing it is what starts the read of how it went: that pass has no
    # company, role or timeline to read the conversation against until now.
    it "is filed by hand, and read back once it is" do
      post(attach_transcript_path(transcript), params: { interview_id: job.id })

      expect(transcript.reload.job_application).to eq(job)
      expect(TranscriptDebriefWorker).to have_received(:perform_async).with(transcript.id)
      expect(response).to redirect_to(interview_transcript_path(job, transcript))
    end

    it "picks up the booking the clock suggested as it files it" do
      note = job.notes.create!(tag: :interview, occurred_at: user.parse_time("2026-10-29 14:00"))

      post(attach_transcript_path(transcript), params: { interview_id: job.id })

      expect(transcript.reload.job_note).to eq(note)
    end

    it "is thrown away on its own" do
      expect { delete(transcript_path(transcript)) }.to change(JobTranscript, :count).by(-1)
    end

    # One press, because it is one thought: the reason this recording is junk
    # is where it came from.
    it "is thrown away along with everything else from that source" do
      expect { post(skip_transcript_path(transcript)) }
        .to change(user.recording_skips, :count).by(1)

      expect(JobTranscript.count).to eq(0)
      expect(user.recording_skips.last.key).to eq("meet.google.com")
      expect(flash[:notice]).to include("Not recording from meet.google.com")
    end

    # A denial nobody can undo is how an interview silently stops being
    # recorded.
    it "starts recording from a source again" do
      skip = user.recording_skips.create!(key: "discord.com")

      expect { delete(unskip_transcripts_path(skip_id: skip.id)) }
        .to change(user.recording_skips, :count).by(-1)
    end

    it "does not touch a recording that is already on an application" do
      transcript.file!(job)

      expect { delete(transcript_path(transcript)) }.not_to(change(JobTranscript, :count))
    end

    it "does not touch somebody else's recording" do
      theirs = create(:user)
      loose = theirs.job_transcripts.create!(turns: [{ "speaker" => "Me", "text" => "Hello." }])

      expect { delete(transcript_path(loose)) }.not_to(change(JobTranscript, :count))
    end
  end
end
