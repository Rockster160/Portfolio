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
end
