require "rails_helper"

# The two halves of a beat on the page: the version written up from his notes,
# and the shorthand it was written from. The readable one is what the timeline
# shows and the one he can edit; the typed one is the record and it stays
# reachable without a page of its own.
RSpec.describe "A beat's two readings", type: :request do
  let(:user) { create(:user) }
  let(:job) { user.job_applications.create!(company: "Podium") }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def shorthand
    <<~NOTES.strip
      Round 3 systems design
        1hr, Coder Pad, 2 prong
        Tips:
          1. ASK QUESTIONS, do NOT jump in
          2. MOST SIMPLISITIC DESIGN POSSIBLE
    NOTES
  end

  def note!(**attrs)
    Sidekiq::Testing.fake! {
      job.notes.create!(tag: :recruiter_call, occurred_at: 1.hour.ago, body: shorthand, **attrs)
    }
  end

  it "shows the written-up version with what he typed behind its own arrow" do
    note!(clean_body: "Round 3 is a 1hr systems design interview in Coder Pad.")

    get interview_path(job)

    expect(response.body).to include("Round 3 is a 1hr systems design interview")
    expect(response.body).to include("As I wrote it")
    expect(response.body).to include("MOST SIMPLISITIC DESIGN POSSIBLE")
  end

  it "shows only what he typed when nothing has been written up" do
    note!

    get interview_path(job)

    expect(response.body).to include("MOST SIMPLISITIC DESIGN POSSIBLE")
    expect(response.body).not_to include("As I wrote it")
  end

  it "lets him edit the written-up version without touching what he typed" do
    note = note!(clean_body: "A first pass at it.")

    patch interview_note_path(job, note), params: {
      job_note: { clean_body: "Round 3 is a systems design interview. Ask questions first." },
    }

    expect(note.reload.clean_body).to include("Ask questions first")
    expect(note.body).to eq(shorthand)
  end

  it "takes a press to write them up again" do
    note = note!(clean_body: "A first pass at it.")

    Sidekiq::Testing.fake! {
      expect { post clean_interview_note_path(job, note) }
        .to change(NoteCleanWorker.jobs, :size).by(1)
    }

    expect(NoteCleanWorker.jobs.last["args"]).to eq([note.id, true])
  end

  # The press is only drawn where there is something to write up. A rejection
  # mail is already prose, and a button offering to tidy one is a call spent on
  # an ATS receipt.
  it "offers the press on a conversation and not on mail" do
    note!

    get interview_path(job)
    expect(response.body).to include("Write these up")

    job.notes.destroy_all
    job.notes.create!(tag: :rejected, occurred_at: 1.hour.ago, body: shorthand)

    get interview_path(job)
    expect(response.body).not_to include("Write these up")
  end
end
