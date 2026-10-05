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

  # Prod 5 Oct, Neighbor. A mail from luke@neighbor.com arranging a technical
  # video interview was filed `interview`. Two things were wrong and the second
  # is the expensive one: it put a conversation on the timeline that had not
  # happened, and because only `scheduled` reaches the calendar, the interview
  # being arranged went on no agenda at all. The seed's rule covered "names a
  # TIME" and "called off" and had nothing to say about either.
  describe "an interview that has not happened yet" do
    it "refuses a time on it, because that is the booking" do
      expect { confirm(tag: :interview, follow_up_at: at, note: "Video interview.") }
        .to raise_error(/takes no follow_up_at/)
    end

    it "refuses one dated ahead of now" do
      expect { confirm(tag: :interview, occurred_at: 2.days.from_now, note: "Video interview.") }
        .to raise_error(/still ahead/)
    end

    # The beat it should have been. Same mail, the tag that books.
    it "takes the booking as scheduled" do
      execute(tag: :scheduled, follow_up_at: at, duration_minutes: 45, note: "Video interview.")
      note = job.notes.last

      expect(note.tag).to eq("scheduled")
      expect(note.follow_up_item.kind).to eq("event")
    end

    # An interview that really did happen is still ordinary: no time on it, and
    # dated when it happened.
    it "still logs one that actually took place" do
      execute(tag: :interview, occurred_at: 1.day.ago, note: "Spoke to Luke for 45 minutes.")

      expect(job.notes.last.tag).to eq("interview")
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

  # Deciding whether a mail really is a rejection means READING it, and the row
  # used to offer no way there - the sublabel is set with textContent (it holds
  # the sender's words) so a link in it renders as literal markdown.
  describe "the mail behind the card" do
    let(:email) {
      user.emails.create!(
        direction: :inbound,
        mail_id:   "pura-1@applytojob.com",
        subject:   "We received your resume",
        blurb:     "Thanks for applying.",
        timestamp: 1.hour.ago.change(usec: 0),
      )
    }

    # Through `confirm`, because the payload a hint really gets is the RESOLVED
    # one and `job_id` only exists there. Built from a hand-written hash, this
    # helper was testing a payload nothing ships: every example here ran with no
    # `job_id`, so "says nothing when there is no mail" passed for the wrong
    # reason and went on passing when it had become wrong.
    def hint(**payload)
      tool[:hint].call(confirm(**payload)[:resolved], ctx)
    end

    it "offers the email to read before the tap" do
      words = hint(email_id: email.id, tag: :rejected)

      expect(words["tap"]).to include("/emails/#{email.id}")
      expect(words["tap"]).to match(/Read the email/)
    end

    # NEVER NOTHING. The receipt is the only other slot that can carry a link and
    # it does not exist until the row is ticked, so a pending card with no hint
    # has nowhere to go at all - which is what a beat with no email we kept was.
    # Neighbor, 5 Oct: "💼 Interview — Neighbor" and one sentence, and his
    # answer was that he could not confirm something carrying no usable
    # information.
    it "offers the row when there is no mail to read" do
      words = hint(tag: :heard_back, note: "They wrote.")

      expect(words["tap"]).to include("/interviews/#{job.id}")
      expect(words["tap"]).to include("ApartmentIQ")
    end

    # The receipt already names and links the row once it has run, and saying it
    # twice is the duplication REMOVAL_TOOLS exists to keep off a row.
    it "leaves the ticked row to its receipt when there was no mail" do
      expect(hint(tag: :heard_back, note: "They wrote.")["done"]).to be_nil
    end

    # Confirming IS reading it, and everything it said is on the board now.
    it "marks it read and archived on confirm" do
      execute(email_id: email.id, tag: :rejected, note: "No thanks.")
      email.reload

      expect(email).to be_read
      expect(email).to be_archived
    end

    # The Ardesian row is a COPY. Gmail mail stays bold in the real inbox until
    # Mail.app is told, and that runs off the tap so a GUI app mid-sync cannot
    # hang a checkbox.
    it "labels the mail on the Mac so it can be cleared by hand" do
      expect(LabelMailWorker).to receive(:perform_async).with(email.id)

      execute(email_id: email.id, tag: :rejected, note: "No thanks.")
    end

    it "leaves a mail that was already filed alone" do
      email.update!(read_at: 2.days.ago, archived_at: 2.days.ago)
      expect(LabelMailWorker).not_to receive(:perform_async)

      execute(email_id: email.id, tag: :rejected, note: "No thanks.")
    end

    # Unticking is a correction about the BOARD, so the mail has to come back
    # out of the archive with the note.
    it "puts the mail back when the row is unticked" do
      resolved = confirm(email_id: email.id, tag: :rejected, note: "No thanks.")
      result   = tool[:execute].call(resolved[:resolved], ctx)
      mail_revert = result[:reverts].find { |r| r[:model] == "Email" }

      expect(mail_revert).to be_present
      expect(mail_revert[:before]).to eq({ "read_at" => nil, "archived_at" => nil })
    end

    it "offers no mail revert when there was no email" do
      resolved = confirm(tag: :heard_back, note: "They wrote.")
      result   = tool[:execute].call(resolved[:resolved], ctx)

      expect(result[:reverts].map { |r| r[:model] }).not_to include("Email")
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
