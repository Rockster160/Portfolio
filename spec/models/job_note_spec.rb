require "rails_helper"

RSpec.describe JobNote do
  let(:user) { create(:user) }
  let(:job) { user.job_applications.create!(company: "Acme") }

  describe "the body" do
    # The tag and the timestamp are a whole fact on their own. Requiring words
    # as well is what put "Applied." underneath a chip already saying APPLIED.
    it "is optional once the note carries a tag" do
      note = job.notes.create!(tag: :applied, occurred_at: 1.day.ago)

      expect(note.body).to be_nil
      expect(note.tag_label).to eq("Applied")
    end

    # An untagged note IS its words. Without them there is nothing there.
    it "is required for an untagged note" do
      note = job.notes.new(tag: :note)

      expect(note).not_to be_valid
      expect(note.errors[:body]).to be_present
    end

    it "stores blank as nothing rather than an empty string" do
      note = job.notes.create!(tag: :interview, body: "   ")

      expect(note.body).to be_nil
    end
  end

  describe "defaults" do
    it "stamps occurred_at with now when nobody said" do
      note = job.notes.create!(body: "Applied.")

      expect(note.occurred_at).to be_within(5.seconds).of(Time.current)
      expect(note.tag).to eq("note")
    end

    it "keeps a timestamp that was set by hand" do
      note = job.notes.create!(body: "Recruiter call", occurred_at: 3.days.ago)

      expect(note.occurred_at).to be_within(5.seconds).of(3.days.ago)
    end
  end

  describe "ordering" do
    it "reads oldest first regardless of when the rows were typed" do
      recent = job.notes.create!(body: "Interview", occurred_at: 1.day.ago)
      older  = job.notes.create!(body: "Applied", occurred_at: 10.days.ago)

      expect(job.notes.reload.map(&:id)).to eq([older.id, recent.id])
    end
  end

  describe "duration_label" do
    it "reads in hours once it passes one" do
      expect(job.notes.new(duration_minutes: 45).duration_label).to eq("45m")
      expect(job.notes.new(duration_minutes: 60).duration_label).to eq("1h")
      expect(job.notes.new(duration_minutes: 75).duration_label).to eq("1h 15m")
      expect(job.notes.new(duration_minutes: nil).duration_label).to be_nil
    end
  end

  # The other half of "heard back": they wrote, you wrote back. It reads as a
  # beat, but it doesn't decide anything about the job.
  describe "the response tag" do
    it "reads as Response and needs no body" do
      note = job.notes.create!(tag: :responded, occurred_at: 1.hour.ago)

      expect(note.tag_label).to eq("Response")
      expect(note.body).to be_nil
    end

    it "sits next to heard back in the dropdown" do
      keys = JobNote::TAG_LABELS.keys

      expect(keys[keys.index("heard_back") + 1]).to eq("responded")
    end

    it "leaves the application where it was" do
      job.notes.create!(tag: :responded)

      expect(job.reload.status).to eq("active")
    end
  end

  describe ".recent" do
    it "reverses the association's own order rather than stacking onto it" do
      old = job.notes.create!(body: "Older", occurred_at: 9.days.ago)
      new = job.notes.create!(body: "Newer", occurred_at: 1.day.ago)

      expect(job.notes.recent.to_a).to eq([new, old])
    end
  end

  # A booked interview is a different animal from a chase: the date on the note
  # is the appointment itself, so it goes on the calendar as a timed event
  # rather than as a task called "Follow up".
  describe "the scheduled tag" do
    it "sits directly above interview in the dropdown" do
      keys = JobNote::TAG_LABELS.keys

      expect(keys[keys.index("scheduled") + 1]).to eq("interview")
    end

    it "writes the interview onto the agenda as an event" do
      at = 3.days.from_now.change(hour: 14, min: 0)
      note = job.notes.create!(tag: :scheduled, follow_up_at: at, duration_minutes: 45)

      item = note.follow_up_item
      expect(item.name).to eq("Interview: Acme")
      expect(item.kind).to eq("event")
      expect(item.end_at).to be_within(1.second).of(at + 45.minutes)
    end

    it "books an hour when nobody said how long" do
      at = 3.days.from_now.change(hour: 14, min: 0)
      note = job.notes.create!(tag: :scheduled, follow_up_at: at)

      expect(note.follow_up_item.end_at).to be_within(1.second).of(at + 1.hour)
    end

    it "still writes an ordinary follow-up as a task with no end" do
      note = job.notes.create!(tag: :heard_back, follow_up_at: 2.days.from_now)

      item = note.follow_up_item
      expect(item.name).to eq("Follow up: Acme")
      expect(item.kind).to eq("task")
      expect(item.end_at).to be_nil
    end

    # Re-tagging has to convert the row it already wrote. Leaving an event
    # wearing a task's fields is how one ends up on the calendar with no end.
    it "converts the agenda row when the tag changes" do
      note = job.notes.create!(tag: :heard_back, follow_up_at: 2.days.from_now)
      note.update!(tag: :scheduled)

      item = note.reload.follow_up_item
      expect(item.kind).to eq("event")
      expect(item.name).to eq("Interview: Acme")
      expect(item.end_at).to be_present

      note.update!(tag: :heard_back)

      item = note.reload.follow_up_item
      expect(item.kind).to eq("task")
      expect(item.end_at).to be_nil
    end

    it "leaves the application active — being booked is not an outcome" do
      job.notes.create!(tag: :scheduled, follow_up_at: 2.days.from_now)

      expect(job.reload.status).to eq("active")
    end
  end

  describe "settling the application" do
    it "marks the job rejected when the newest note says so" do
      job.notes.create!(body: "No thanks", tag: :rejected)

      expect(job.reload.status).to eq("rejected")
    end

    it "marks the job as an offer" do
      job.notes.create!(body: "They offered", tag: :offer)

      expect(job.reload.status).to eq("offer")
    end

    it "closes the job when you withdrew" do
      job.notes.create!(body: "Took the other one", tag: :withdrew)

      expect(job.reload.status).to eq("closed")
    end

    it "leaves the job alone for an ordinary note" do
      job.notes.create!(body: "Nice office", tag: :interview)

      expect(job.reload.status).to eq("active")
    end

    # Typing up an old rejection after the job came back to life would
    # otherwise silently kill it again.
    it "ignores a back-dated note that isn't the newest" do
      job.notes.create!(body: "Rejected back then", tag: :rejected, occurred_at: 30.days.ago)
      job.update!(status: :active)
      job.notes.create!(body: "They reopened it", tag: :heard_back, occurred_at: 1.day.ago)

      job.notes.create!(body: "Another old rejection", tag: :rejected, occurred_at: 20.days.ago)

      expect(job.reload.status).to eq("active")
    end
  end

  describe ".follow_ups_for" do
    # A chase you missed is more outstanding than one that hasn't come round
    # yet. Putting a floor at "today" quietly retired them, which is the one
    # thing a tracker must not do.
    it "keeps a missed follow-up, and puts it first" do
      soon = job.notes.create!(body: "Friday", follow_up_at: 3.days.from_now)
      late = job.notes.create!(body: "Last week", follow_up_at: 6.days.ago)

      expect(described_class.follow_ups_for(user).map(&:id)).to eq([late.id, soon.id])
    end

    it "drops the ones on an application that is over" do
      job.notes.create!(body: "Chase", follow_up_at: 2.days.from_now)
      job.update!(status: :rejected)

      expect(described_class.follow_ups_for(user)).to be_empty
    end

    it "ignores notes with no follow-up at all" do
      job.notes.create!(body: "Just a thought")

      expect(described_class.follow_ups_for(user)).to be_empty
    end

    it "never reaches into somebody else's search" do
      theirs = create(:user).job_applications.create!(company: "Theirs")
      theirs.notes.create!(body: "Chase", follow_up_at: 2.days.from_now)

      expect(described_class.follow_ups_for(user)).to be_empty
    end

    describe "due_now" do
      it "is the missed and the due-today, not the ones still ahead" do
        missed = job.notes.create!(body: "Last week", follow_up_at: 6.days.ago)
        today  = job.notes.create!(body: "This evening", follow_up_at: 1.hour.from_now)
        job.notes.create!(body: "Friday", follow_up_at: 3.days.from_now)

        expect(described_class.follow_ups_for(user).due_now.map(&:id)).to eq([missed.id, today.id])
      end
    end
  end

  describe "follow-ups" do
    # Every account gets one on save (User#ensure_default_agenda); the
    # follow-up lands on the oldest writable one unless a preference says
    # otherwise.
    let(:agenda) { user.agendas.order(:id).first }

    it "writes the follow-up onto the agenda as a task" do
      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      item = AgendaItem.find(note.reload.agenda_item_id)
      expect(item.agenda_id).to eq(agenda.id)
      expect(item.kind).to eq("task")
      expect(item.name).to eq("Follow up: Acme")
      expect(item.color).to eq(job.color)
      expect(item.start_at).to be_within(5.seconds).of(3.days.from_now)
    end

    it "moves the existing task rather than adding a second one" do
      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)
      original_id = note.reload.agenda_item_id

      note.update!(follow_up_at: 5.days.from_now)

      expect(note.reload.agenda_item_id).to eq(original_id)
      expect(AgendaItem.count).to eq(1)
      expect(AgendaItem.first.start_at).to be_within(5.seconds).of(5.days.from_now)
    end

    it "takes the task back off when the follow-up is cleared" do
      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      note.update!(follow_up_at: nil)

      expect(note.reload.agenda_item_id).to be_nil
      expect(AgendaItem.count).to be_zero
    end

    it "takes the task with it when the note is deleted" do
      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      note.destroy!

      expect(AgendaItem.count).to be_zero
    end

    it "carries no calendar notes when the note had no body" do
      note = job.notes.create!(tag: :interview, follow_up_at: 3.days.from_now)

      expect(AgendaItem.find(note.reload.agenda_item_id).notes).to be_nil
    end

    it "writes nothing when there is no follow-up" do
      note = job.notes.create!(body: "Just a thought")

      expect(note.agenda_item_id).to be_nil
      expect(AgendaItem.count).to be_zero
    end

    it "goes on the Tasks calendar" do
      tasks = create(:agenda, user: user, name: "Tasks")

      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      expect(AgendaItem.find(note.reload.agenda_item_id).agenda_id).to eq(tasks.id)
    end

    # A calendar name is typed by a person, and one on this account ends in a
    # space — an exact match would quietly miss it and write somewhere else.
    it "finds Tasks through stray case and whitespace" do
      tasks = create(:agenda, user: user, name: " tasks ")

      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      expect(AgendaItem.find(note.reload.agenda_item_id).agenda_id).to eq(tasks.id)
    end

    # Naming a destination beats a general "where do new items go" preference.
    it "prefers Tasks over the agenda default" do
      tasks = create(:agenda, user: user, name: "Tasks")
      other = create(:agenda, user: user)
      AgendaPreference.for(user).update!(default_agenda_id: other.id)

      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      expect(AgendaItem.find(note.reload.agenda_item_id).agenda_id).to eq(tasks.id)
    end

    it "falls back to the chosen default when there is no Tasks calendar" do
      other = create(:agenda, user: user)
      AgendaPreference.for(user).update!(default_agenda_id: other.id)

      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      expect(AgendaItem.find(note.reload.agenda_item_id).agenda_id).to eq(other.id)
    end

    # A Google calendar only accepts events, and a follow-up is a task. Writing
    # one there fails validation rather than syncing, so it's skipped.
    it "skips a Google-managed calendar" do
      user.agendas.each { |a| a.update_columns(source: Agenda.sources[:google]) }

      note = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)

      expect(note.reload.agenda_item_id).to be_nil
      expect(AgendaItem.count).to be_zero
    end
  end
end
