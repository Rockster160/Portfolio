require "rails_helper"

# WHICH BEATS GET WRITTEN UP, which is the whole question this worker answers.
# A timeline is mostly mail - confirmations, rejections, ATS receipts - and all
# of it is already prose. The beats worth a call are the ones he typed himself
# during a conversation, and `conversation?` is already the app's answer to
# that question: it is what decides whether a beat gets the two sentiment
# sliders, for the same reason.
RSpec.describe NoteCleanWorker do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }

  def shorthand
    <<~NOTES.strip
      Round 3 systems design
        1hr, Coder Pad, 2 prong
        Tips:
          1. ASK QUESTIONS, do NOT jump in
          2. MOST SIMPLISITIC DESIGN POSSIBLE
          3. think of the UNHAPPY PATH
    NOTES
  end

  def note!(tag:, body: shorthand)
    job.notes.create!(tag: tag, occurred_at: 1.hour.ago, body: body)
  end

  # The suite runs workers inline, so filing a beat would otherwise reach the
  # real client the moment it is created and there would be nothing to count.
  around { |example| Sidekiq::Testing.fake! { example.run } }

  describe "what gets queued on its own" do
    it "queues a call he was in the room for" do
      expect { note!(tag: :recruiter_call) }.to change(described_class.jobs, :size).by(1)
    end

    it "queues an interview" do
      expect { note!(tag: :interview) }.to change(described_class.jobs, :size).by(1)
    end

    it "leaves mail alone" do
      expect { note!(tag: :rejected) }.not_to change(described_class.jobs, :size)
    end

    it "leaves a one-line beat alone" do
      expect { note!(tag: :interview, body: "Went well.") }
        .not_to change(described_class.jobs, :size)
    end

    # A beat filed by a script that wrote both halves is not waiting to be read
    # by anything, and a pass over it would replace the version that was
    # deliberately written.
    it "leaves a beat that arrived with its own written-up version alone" do
      expect {
        job.notes.create!(
          tag:         :recruiter_call,
          occurred_at: 1.hour.ago,
          body:        shorthand,
          clean_body:  "Round 3 is a systems design interview.",
        )
      }.not_to change(described_class.jobs, :size)
    end
  end

  describe "performing" do
    it "writes the readable version" do
      note = note!(tag: :recruiter_call)
      allow(Notes::Clean).to receive(:call).and_return(
        Notes::Clean::Result.new(ok: true, chars: 400),
      )

      described_class.new.perform(note.id)

      expect(Notes::Clean).to have_received(:call).with(note_matching(note), again: false)
    end

    it "passes the press through as a second pass" do
      note = note!(tag: :recruiter_call)
      allow(Notes::Clean).to receive(:call).and_return(
        Notes::Clean::Result.new(ok: true, chars: 400),
      )

      described_class.new.perform(note.id, true)

      expect(Notes::Clean).to have_received(:call).with(note_matching(note), again: true)
    end

    it "does nothing for a beat since deleted" do
      allow(Notes::Clean).to receive(:call)

      described_class.new.perform(0)

      expect(Notes::Clean).not_to have_received(:call)
    end
  end

  def note_matching(note)
    satisfy { |found| found.id == note.id }
  end
end
