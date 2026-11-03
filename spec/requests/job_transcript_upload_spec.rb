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

  # `ingest!` reads the tempfile to the end before the attach, and an IO at EOF
  # attaches as an empty file - the upload would be on the page, nameable and
  # readable, with nothing behind the download link. Labelled or not, the file
  # never said which speaker is him, so the speakers pass always starts.
  it "reads the file into turns, keeps it as dropped, starts the speakers pass and lands on it", :aggregate_failures do
    post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })

    transcript = job.transcripts.first
    expect(transcript.turns.length).to eq(2)
    expect(transcript.file).to be_attached
    expect(transcript.file.download).to eq(body)
    expect(TranscriptSpeakersWorker).to have_received(:perform_async).with(transcript.id)
    expect(response).to redirect_to(interview_transcript_path(job, transcript))

    follow_redirect!
    expect(response.body).to include("How do you handle disagreeing with a teammate?")
  end

  describe "pasting the words instead of a file" do
    let(:spoken) {
      "Thanks for making the time today. Happy to be here, I was looking forward to it."
    }

    # The paste is written as the text file it would have been, so there is one
    # thing to reread when the parse got the conversation wrong.
    it "reads a paste into a conversation kept as a .txt file, like any upload", :aggregate_failures do
      post(interview_transcripts_path(job), params: { job_transcript: { text: spoken } })

      transcript = job.transcripts.first
      expect(transcript.turns.length).to eq(1)
      expect(transcript.turns.first["text"]).to include("looking forward to it")
      expect(response).to redirect_to(interview_transcript_path(job, transcript))
      expect(transcript.file).to be_attached
      expect(transcript.file.download).to eq(spoken)
      expect(transcript.file.filename.to_s).to end_with(".txt")
      expect(TranscriptSpeakersWorker).to have_received(:perform_async).with(transcript.id)
    end

    it "takes the title and the beat typed beside it" do
      note = job.notes.create!(
        body: "Spoke to the hiring manager", tag: :interview, occurred_at: 1.day.ago,
      )

      post(interview_transcripts_path(job), params: {
        job_transcript: { text: spoken, title: "Hiring manager round", job_note_id: note.id },
      })

      transcript = job.transcripts.first
      expect(transcript.label).to eq("Hiring manager round")
      expect(transcript.job_note_id).to eq(note.id)
    end

  end

  # A conversation and the beat saying it happened are one thing that happened.
  describe "logging the conversation with the beat" do
    let(:note_params) {
      {
        job_note: {
          body:        "Hour with the hiring manager, mostly system design.",
          tag:         :interview,
          occurred_at: Time.current.strftime("%Y-%m-%dT%H:%M"),
        },
      }
    }

    it "files the recording against the beat the same submit created" do
      post(interview_notes_path(job), params: note_params.merge(
        job_transcript: { file: transcript_file(body) },
      ))

      note = job.notes.last
      transcript = job.transcripts.first
      expect(transcript.job_note_id).to eq(note.id)
      expect(transcript.turns.length).to eq(2)
      expect(response).to redirect_to(interview_path(job))
    end

    it "takes a paste there too" do
      post(interview_notes_path(job), params: note_params.merge(
        job_transcript: { text: "So tell me how you would scale the writes." },
      ))

      expect(job.transcripts.first.job_note_id).to eq(job.notes.last.id)
    end

    it "logs the beat on its own when no recording came with it" do
      post(interview_notes_path(job), params: note_params)

      expect(job.notes.size).to eq(1)
      expect(job.transcripts).to be_empty
      expect(flash[:alert]).to be_blank
    end

    # The note is the part that was typed. A recording that could not be read
    # is one that can be handed over again, and losing the note with it would
    # mean typing the whole thing twice.
    it "keeps the beat when the words could not be read as a conversation" do
      allow(Transcripts::Intake).to receive(:call).and_raise(StandardError, "nope")

      post(interview_notes_path(job), params: note_params.merge(
        job_transcript: { text: "something" },
      ))

      expect(job.notes.size).to eq(1)
      expect(flash[:alert]).to be_present
    end

    it "offers the recording on the beat form rather than only in the panel" do
      get(interview_path(job))

      expect(response.body).to include("multipart/form-data")
    end
  end

  # Half an hour of talking is 120 turns, and what is asked of it afterwards is
  # a lookup, on its own page and under the beat in the timeline.
  describe "finding a line in it" do
    it "offers the box on the transcript's own page" do
      post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })

      get(interview_transcript_path(job, job.transcripts.first))

      expect(response.body).to include("data-transcript-query")
      expect(response.body).to include("data-turn-text")
    end

    it "reads the conversation under the beat in the timeline, box and all" do
      note = job.notes.create!(
        body: "Hiring manager round", tag: :interview, occurred_at: 1.day.ago,
      )
      post(interview_transcripts_path(job), params: {
        job_transcript: { file: transcript_file(body), job_note_id: note.id },
      })

      get(interview_path(job))

      expect(response.body).to include("I would rather have the argument early.")
      expect(response.body).to include("data-transcript-search")
    end
  end

  # Dropping it in is the whole instruction: who was talking is read off the
  # file, so there is nothing to press afterwards.
  describe "working out who was talking" do
    let(:unlabelled) {
      <<~VTT
        00:00:01 --> 00:00:04
        Thanks for making the time today.

        00:00:06 --> 00:00:11
        Happy to be here, I was looking forward to it.
      VTT
    }

    it "starts the pass off an unlabelled upload too" do
      post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(unlabelled) } })

      expect(TranscriptSpeakersWorker).to have_received(:perform_async).with(job.transcripts.first.id)
    end

    # Dropping a file in and landing on a page that looks exactly like a failed
    # read is the thing that makes a minute feel like a hang.
    it "says on the page that the reading is under way, and how far along" do
      post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(unlabelled) } })
      transcript = job.transcripts.first
      BackgroundProcess.note(
        user:    user,
        key:     Transcripts::Speakers.key_for(transcript),
        name:    "Reading the recording",
        current: 2,
        total:   5,
      )

      get(interview_transcript_path(job, transcript))

      expect(response.body).to include("Reading the recording")
      expect(response.body).to include("http-equiv=\"refresh\"")
    end

    it "says nothing about reading once the pass is done with it" do
      post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(unlabelled) } })

      get(interview_transcript_path(job, job.transcripts.first))

      expect(response.body).not_to include("Reading the recording")
      expect(response.body).not_to include("http-equiv=\"refresh\"")
    end
  end

  # The local job hunter rebuilds his spoken answers from a recording, and the
  # one thing it needs is which turns are his.
  describe "the conversation as data" do
    it "says which side each turn is on, and what to call them" do
      post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })
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
      post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })

      get(interview_transcript_path(job, job.transcripts.first, format: :json))

      expect(response.parsed_body["turns"].pluck("who")).to all(eq("unknown"))
    end

    it "names the recordings on the board's own list" do
      post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })

      get(interviews_path(format: :json, status: :all))

      found = response.parsed_body["jobs"].find { |row| row["id"] == job.id }
      expect(found["transcripts"].first).to include("turn_count" => 2, "placed" => false)
    end
  end

  it "redirects back rather than erroring when no file was picked, or only spaces were pasted" do
    [{}, { job_transcript: { text: "   \n  " } }].each do |params|
      post(interview_transcripts_path(job), params: params)

      expect(response).to redirect_to(interview_path(job))
      expect(flash[:alert]).to be_present
    end
    expect(job.transcripts).to be_empty
  end

  # ONE SUBMIT FOR THE WHOLE PAGE: naming a speaker and moving a turn onto the
  # right one are done while reading, and they post together.
  it "names the speakers and moves a turn in one save" do
    post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })
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
    expect(transcript.turns.pluck("speaker")).to eq(["Speaker 1", "Speaker 2"])
  end

  # The drop zone has to be in the markup for the script to find it.
  it "offers somewhere to drop a file" do
    get(interview_path(job))

    expect(response.body).to include("data-drop")
  end

  it "shows the transcript on the interview page once it is there" do
    post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })

    get(interview_path(job))

    expect(response.body).to include("bluestaq hiring manager")
  end

  # A transcript is reached through the job it belongs to, so an id lifted onto
  # another application finds nothing - and the app turns finding nothing into
  # the login redirect rather than showing the conversation.
  it "refuses a transcript belonging to another application" do
    other = user.job_applications.create!(company: "Elsewhere")
    post(interview_transcripts_path(job), params: { job_transcript: { file: transcript_file(body) } })
    transcript = job.transcripts.first

    get(interview_transcript_path(other, transcript))

    expect(response.body).not_to include("I would rather have the argument early.")
    expect(response).to have_http_status(:redirect)
  end
end
