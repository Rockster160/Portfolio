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
