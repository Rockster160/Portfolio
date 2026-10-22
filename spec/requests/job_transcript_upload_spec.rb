require "rails_helper"

# Dropping a recording onto an interview. The whole point is that it is one
# step - pick the file, press the button - and that what comes back is a
# readable conversation rather than a file you have to open somewhere else.
RSpec.describe "Job transcript upload", type: :request do
  let(:user) { User.me }
  let(:body) {
    <<~VTT
      00:00:01 --> 00:00:04
      Speaker 1: How do you handle disagreeing with a teammate?

      00:00:05 --> 00:00:09
      Speaker 2: I would rather have the argument early.
    VTT
  }
  let(:job) { user.job_applications.create!(company: "Bluestaq", role: "Senior Engineer") }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post(login_path, params: { user: { username: user.username, password: "password123" } })
    # Every upload starts the pass on who was talking. There is no queue in a
    # spec, and what it does with the file has its own.
    allow(TranscriptSpeakersWorker).to receive(:perform_async)
  end

  def transcript_file(body, name: "bluestaq-hiring-manager.txt")
    file = Tempfile.new(["transcript", ".txt"])
    file.write(body)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: name)
  end

  it "reads the file into turns and lands on the conversation" do
    post(interview_transcripts_path(job), params: { file: transcript_file(body) })

    transcript = job.transcripts.first
    expect(transcript.turns.length).to eq(2)
    expect(response).to redirect_to(interview_transcript_path(job, transcript))

    follow_redirect!
    expect(response.body).to include("How do you handle disagreeing with a teammate?")
  end

  # `ingest!` reads the tempfile to the end before the attach, and an IO at EOF
  # attaches as an empty file - the upload would be on the page, nameable and
  # readable, with nothing behind the download link.
  it "keeps the file as it was dropped in" do
    post(interview_transcripts_path(job), params: { file: transcript_file(body) })

    transcript = job.transcripts.first
    expect(transcript.file).to be_attached
    expect(transcript.file.download).to eq(body)
  end

  # DROPPING IT IN IS THE WHOLE INSTRUCTION. Whether the file needs splitting
  # into sides or just needs telling which of its labels is him is something it
  # can be read off, so there is nothing to press afterwards.
  describe "working out who was talking" do
    let(:unlabelled) {
      <<~VTT
        00:00:01 --> 00:00:04
        Thanks for making the time today.

        00:00:06 --> 00:00:11
        Happy to be here, I was looking forward to it.
      VTT
    }

    it "starts the pass off the upload, with nothing to press" do
      post(interview_transcripts_path(job), params: { file: transcript_file(unlabelled) })

      expect(TranscriptSpeakersWorker).to have_received(:perform_async)
        .with(job.transcripts.first.id)
    end

    it "starts it for a file that named people too, which still never said which is him" do
      post(interview_transcripts_path(job), params: { file: transcript_file(body) })

      expect(TranscriptSpeakersWorker).to have_received(:perform_async)
        .with(job.transcripts.first.id)
    end

    it "asks nothing on the page about who was talking" do
      post(interview_transcripts_path(job), params: { file: transcript_file(unlabelled) })
      get(interview_transcript_path(job, job.transcripts.first))

      expect(response.body).not_to include("Work out which of these are me")
      expect(response.body).to include("read off the recording when it lands")
    end
  end

  # The local job hunter pulls questions out of a recording and rebuilds his
  # spoken answers from them, and the one thing it needs is which turns are
  # his. That is settled here now, on the board, rather than by a second pass
  # over its own copy of the same file.
  describe "the conversation as data" do
    it "says which side each turn is on, and what to call them" do
      post(interview_transcripts_path(job), params: { file: transcript_file(body) })
      transcript = job.transcripts.first
      transcript.rename_speakers!(
        "Speaker 1" => { "name" => "Casey" },
        "Speaker 2" => { "name" => "Rocco", "me" => "1" },
      )

      get(interview_transcript_path(job, transcript, format: :json))

      said = response.parsed_body
      expect(said["company"]).to eq("Bluestaq")
      expect(said["turns"].pluck("who")).to eq(%w[them me])
      expect(said["turns"].first["speaker"]).to eq("Casey")
      expect(said["turns"].first["text"]).to include("disagreeing with a teammate")
    end

    it "says plainly when a turn is on nobody yet" do
      post(interview_transcripts_path(job), params: { file: transcript_file(body) })

      get(interview_transcript_path(job, job.transcripts.first, format: :json))

      expect(response.parsed_body["turns"].pluck("who")).to all(eq("unknown"))
    end

    it "names the recordings on the board's own list" do
      post(interview_transcripts_path(job), params: { file: transcript_file(body) })

      get(interviews_path(format: :json, status: :all))

      found = response.parsed_body["jobs"].find { |row| row["id"] == job.id }
      expect(found["transcripts"].first).to include("turn_count" => 2, "placed" => false)
    end
  end

  it "says so rather than erroring when no file was picked" do
    post(interview_transcripts_path(job))

    expect(response).to redirect_to(interview_path(job))
    expect(flash[:alert]).to include("Pick a transcript file")
    expect(job.transcripts).to be_empty
  end

  # ONE SUBMIT FOR THE WHOLE PAGE: naming a speaker and moving a turn onto the
  # right one are done while reading, and they post together.
  it "names the speakers and moves a turn in one save" do
    post(interview_transcripts_path(job), params: { file: transcript_file(body) })
    transcript = job.transcripts.first

    patch(interview_transcript_path(job, transcript), params: {
      speakers: {
        "Speaker 1" => { "name" => "Casey Holm", "me" => "0" },
        "Speaker 2" => { "name" => "Rocco", "me" => "1" },
      },
      turns:    { "0" => "Speaker 1", "1" => "Speaker 2" },
    })

    transcript.reload
    expect(transcript.name_for("Speaker 2")).to eq("Rocco")
    expect(transcript).to be_mine("Speaker 2")
    expect(flash[:notice]).to eq("Saved.")
  end

  # "If I can, it's not clear that I can or where I should drop it." The zone is
  # the instruction, and it has to be in the markup for the script to find it.
  it "offers somewhere to drop a file" do
    get(interview_path(job))

    expect(response.body).to include("data-drop")
    expect(response.body).to include("Drop a transcript here")
  end

  it "shows the transcript on the interview page once it is there" do
    post(interview_transcripts_path(job), params: { file: transcript_file(body) })

    get(interview_path(job))

    expect(response.body).to include("bluestaq hiring manager")
  end

  # A transcript is reached through the job it belongs to, so an id lifted onto
  # another application finds nothing - and the app turns finding nothing into
  # the login redirect rather than showing the conversation.
  it "refuses a transcript belonging to another application" do
    other = user.job_applications.create!(company: "Elsewhere")
    post(interview_transcripts_path(job), params: { file: transcript_file(body) })
    transcript = job.transcripts.first

    get(interview_transcript_path(other, transcript))

    expect(response.body).not_to include("I would rather have the argument early.")
    expect(response).to have_http_status(:redirect)
  end
end
