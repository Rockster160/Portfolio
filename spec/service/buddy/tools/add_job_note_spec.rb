require "rails_helper"

# Prod 56/57, 16 Sep. ApartmentIQ's calendar invite and Ashley's confirmation
# email arrived five seconds apart, so the same booking was announced twice —
# and BOTH cards proposed a Scheduled note with no `follow_up_at`. The time was
# sitting in each card's own summary line ("Sep 17 at 2pm MDT") and in neither
# of their fields, so `sync_follow_up` returned early both times and the day the
# interview was booked for stayed empty.
RSpec.describe "add_job_note tool" do
  let(:user) { create(:user) }
  let(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:ctx) { Buddy::ToolContext.new(user, conversation: conversation) }
  let(:tool) { Buddy::Tools[:add_job_note] }
  let!(:job) { user.job_applications.create!(company: "ApartmentIQ") }
  let(:at) { 2.days.from_now.change(hour: 14, min: 0, sec: 0, usec: 0) }

  def confirm(**payload)
    tool[:confirm].call({ company: "ApartmentIQ" }.merge(payload), ctx)
  end

  def execute(**payload)
    tool[:execute].call(confirm(**payload)[:resolved], ctx)
  end

  describe "a booked interview" do
    it "puts the appointment on the calendar as a timed event" do
      execute(tag: :scheduled, follow_up_at: at, duration_minutes: 20, note: "Phone screen.")
      note = job.notes.last

      expect(note.follow_up_item.kind).to eq("event")
      expect(note.follow_up_item.start_at).to eq(at)
      expect(note.follow_up_item.end_at).to eq(at + 20.minutes)
    end

    # The whole failure: a Scheduled row that claims an interview and cannot say
    # when, which writes nothing to the agenda and says nothing about it.
    it "refuses to book one with no time" do
      expect { confirm(tag: :scheduled, note: "Interview on Thursday at 2pm.") }
        .to raise_error(/needs its time/)
    end

    it "takes the mail's own length rather than assuming an hour" do
      execute(tag: :scheduled, follow_up_at: at, duration_minutes: 20)

      expect(job.notes.last.duration_minutes).to eq(20)
    end

    it "still books an hour when the mail never said" do
      execute(tag: :scheduled, follow_up_at: at)

      expect(job.notes.last.follow_up_item.end_at).to eq(at + 60.minutes)
    end

    # The invite and the confirmation are two separate mails, so each is its own
    # turn and no merge_key can see the other. Left alone, the appointment lands
    # on the agenda twice.
    it "refuses a second booking at the same minute" do
      execute(tag: :scheduled, follow_up_at: at, note: "The invite.")

      expect { confirm(tag: :scheduled, follow_up_at: at, note: "The confirmation.") }
        .to raise_error(/already booked for then/)
    end

    # A different time is a reschedule, not a duplicate.
    it "allows one that moved" do
      execute(tag: :scheduled, follow_up_at: at, note: "The invite.")

      expect { confirm(tag: :scheduled, follow_up_at: at + 1.day, note: "Moved.") }
        .not_to raise_error
    end
  end

  # Prod 15 Sep: three Aledade PBC roles applied to in one day. The resolver
  # took a company and only a company and answered with the first row, so two of
  # those jobs were filed onto a third one's timeline — three separate outcomes
  # set to resolve as one.
  describe "a company with more than one job on the board" do
    let!(:backend) {
      user.job_applications.create!(company: "ApartmentIQ", role: "Senior Backend Engineer")
    }

    it "picks the row whose role the beat names" do
      execute(role: "Senior Backend Engineer", tag: :acknowledged, note: "Got it.")

      expect(backend.notes.count).to eq(1)
      expect(job.notes.count).to be_zero
    end

    # `role` is the explicit way to say it; the words of the mail are the one
    # that actually turns up, since an ATS receipt quotes the title back.
    it "reads the role out of the mail's own words" do
      execute(note: "Thanks for applying to the Senior Backend Engineer role.", tag: :acknowledged)

      expect(backend.notes.count).to eq(1)
    end

    # Answerable beats silent. A note on the wrong job is permanent; a question
    # naming the roles can simply be answered.
    it "asks which one rather than picking" do
      expect { confirm(tag: :heard_back, note: "They wrote back.") }
        .to raise_error(/has 2 applications on the board.*Senior Backend Engineer/m)
    end

    it "asks again rather than guessing when the role names neither" do
      expect { confirm(role: "Designer", tag: :heard_back, note: "They wrote.") }
        .to raise_error(/has 2 applications/)
    end
  end

  # On every other tag `follow_up_at` is a chase, stays optional, and goes on
  # the agenda as a task.
  describe "everything that is not a booking" do
    it "wants no time at all" do
      expect { confirm(tag: :heard_back, note: "They wrote back.") }.not_to raise_error
    end

    it "writes an availability chase as a task saying what is owed" do
      execute(tag: :availability, follow_up_at: at, note: "Send times.")
      item = job.notes.last.follow_up_item

      expect(item.kind).to eq("task")
      expect(item.name).to eq("Send availability: ApartmentIQ")
    end
  end
  # Buddy::JobMailOffer files arriving mail on its row as a plain `note`, so
  # this card is the READING of a row that already exists rather than a new one.
  describe "a mail this row already holds" do
    let(:email) {
      user.emails.create!(
        direction: :inbound,
        mail_id:   "m-9",
        subject:   "Thanks for applying",
        blurb:     "Thanks!",
        timestamp: 1.hour.ago.change(usec: 0),
      )
    }
    let!(:filed) {
      note = job.notes.create!(body: "Thanks!", tag: :note, occurred_at: email.timestamp)
      email.update!(job_triage: email.job_triage.merge(job_note_id: note.id))
      note
    }

    it "revises it rather than filing a second one" do
      expect {
        execute(tag: :acknowledged, email_id: email.id, note: "Thanks!")
      }.not_to(change { job.notes.count })

      expect(filed.reload.tag).to eq("acknowledged")
    end

    # Unticking must put the tag back, never take the mail off the board.
    it "undoes to the tag it had, not to nothing" do
      result = execute(tag: :rejected, email_id: email.id, note: "No thanks.")
      revert = result[:reverts].first

      expect(revert[:op]).to eq("updated")
      expect(revert[:id]).to eq(filed.id)
      expect(revert[:before]["tag"]).to eq("note")
    end

    # A mail filed against one row must never be dragged onto another by an id.
    it "leaves another application's filed mail alone" do
      other = user.job_applications.create!(company: "Elsewhere")
      email.update!(job_triage: email.job_triage.merge(job_note_id: other.notes.create!(
        body: "Different row.", tag: :note, occurred_at: email.timestamp,
      ).id))

      expect {
        execute(tag: :acknowledged, email_id: email.id, note: "Thanks!")
      }.to change { job.notes.count }.by(1)
    end

    it "still creates when nothing has filed the mail yet" do
      email.update!(job_triage: {})

      expect {
        execute(tag: :acknowledged, email_id: email.id, note: "Thanks!")
      }.to change { job.notes.count }.by(1)
    end

    # JobNote#settle_receipt_after_applied hangs off the note becoming a
    # receipt, which for a filed mail is an UPDATE rather than a create.
    it "still pulls an applied beat back behind the receipt on a retag" do
      applied = job.notes.create!(tag: :applied, occurred_at: email.timestamp + 5.minutes)

      execute(tag: :acknowledged, email_id: email.id, note: "Thanks!")

      expect(applied.reload.occurred_at).to be < email.timestamp
    end
  end
end
