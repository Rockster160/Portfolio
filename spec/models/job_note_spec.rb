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

    # Indentation is how someone hangs sub-notes off a line. `strip` took it off
    # the FIRST line and left it on the rest, which is ragged in exactly the
    # case the indentation was there for.
    it "keeps the indentation, including on the first line" do
      note = job.notes.create!(body: "\n\n    Call notes:\n      - asked about Rails\n\n")

      expect(note.body).to eq("    Call notes:\n      - asked about Rails")
    end

    # Pasted email arrives full of CRLF, and a stray \r is one more invisible
    # character to reason about later.
    it "normalizes Windows line endings" do
      note = job.notes.create!(body: "Hi Rocco,\r\n\r\nMonday works.")

      expect(note.body).to eq("Hi Rocco,\n\nMonday works.")
    end
  end

  describe "defaults" do
    it "stamps occurred_at with now when nobody said, and keeps one set by hand" do
      note = job.notes.create!(body: "Applied.")
      expect(note.occurred_at).to be_within(5.seconds).of(Time.current)
      expect(note.tag).to eq("note")

      dated = job.notes.create!(body: "Recruiter call", occurred_at: 3.days.ago)
      expect(dated.occurred_at).to be_within(5.seconds).of(3.days.ago)
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

  # A beat that is a whole fact without words, and decides nothing about the
  # application.
  it "needs no body for a beat, and leaves the application active for one that settles nothing", :aggregate_failures do
    %i[responded acknowledged availability cancelled].each do |tag|
      note = job.notes.create!(tag: tag, occurred_at: 1.hour.ago)
      expect(note.body).to be_nil, tag.to_s
    end
    job.notes.create!(tag: :scheduled, follow_up_at: 2.days.from_now)

    expect(job.reload.status).to eq("active")
  end

  # The submission came before the receipt for it, whichever was written first.
  describe "an applied beat and its receipt" do
    it "moves an applied written after the receipt to just before it" do
      receipt = job.notes.create!(tag: :acknowledged, occurred_at: 10.minutes.ago)
      applied = job.notes.create!(tag: :applied, occurred_at: 2.minutes.ago)

      expect(applied.reload.occurred_at).to eq(receipt.occurred_at - 1.second)
    end

    # jobhunt can write applied first, and a receipt filed later carries the
    # mail's earlier time.
    it "moves an applied already there when an earlier receipt lands" do
      applied = job.notes.create!(tag: :applied, occurred_at: 2.minutes.ago)
      receipt = job.notes.create!(tag: :acknowledged, occurred_at: 5.minutes.ago)

      expect(applied.reload.occurred_at).to eq(receipt.occurred_at - 1.second)
      expect(job.reload.last_activity_at).to eq(receipt.occurred_at)
    end

    it "never moves an applied that is already before the receipt" do
      applied = job.notes.create!(tag: :applied, occurred_at: 1.day.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 1.hour.ago)

      expect(applied.reload.occurred_at).to be_within(1.second).of(1.day.ago)
    end

    it "leaves another application's applied alone" do
      other   = user.job_applications.create!(company: "Other")
      applied = other.notes.create!(tag: :applied, occurred_at: 2.minutes.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 5.minutes.ago)

      expect(applied.reload.occurred_at).to be_within(1.second).of(2.minutes.ago)
    end
  end

  # A recruiter came to him about something he does not want. `withdrew` is them
  # pulling out and `rejected` says they said no, so neither is honest.
  describe "the ignored tag" do
    it "settles the application as ignored, with nothing owed on it" do
      job.notes.create!(tag: :reached_out, occurred_at: 2.days.ago, body: "Got a role for you")
      note = job.notes.create!(tag: :ignored, occurred_at: 1.hour.ago)

      expect(note.body).to be_nil
      expect(job.reload.status).to eq("ignored")
      expect(job.dead?).to be(true)
      expect(job.owed_now).to be_nil
    end
  end

  describe ".recent" do
    it "reverses the association's own order rather than stacking onto it" do
      old = job.notes.create!(body: "Older", occurred_at: 9.days.ago)
      new = job.notes.create!(body: "Newer", occurred_at: 1.day.ago)

      expect(job.notes.recent.to_a).to eq([new, old])
    end
  end

  # `scheduled` says a time is AGREED and books it as a timed event; a request
  # for times is a thing owed, so it goes on the agenda as a task.
  describe "the availability tag" do
    it "puts what he owes on the agenda as a task, not an interview" do
      note = job.notes.create!(tag: :availability, follow_up_at: 2.days.from_now.change(hour: 9, min: 0))
      item = note.follow_up_item

      expect(item.kind).to eq("task")
      expect(item.end_at).to be_nil
    end
  end

  # A rejection or withdrawal ends the process, so every future booking on the
  # row comes off the calendar however long ago it was made. History stays, and
  # the booking note itself stays as the record that a round was booked. An
  # offer is not an ending: the last round can be booked after it.
  describe "an application ending" do
    it "takes every future interview off the calendar on a rejection, keeping the notes and the past", :aggregate_failures do
      past    = job.notes.create!(tag: :scheduled, follow_up_at: 2.days.ago)
      old     = travel_to(3.weeks.ago) { job.notes.create!(tag: :scheduled, follow_up_at: 30.days.from_now) }
      booking = job.notes.create!(tag: :scheduled, follow_up_at: 12.days.from_now.change(hour: 8, min: 0))
      item    = booking.follow_up_item
      expect(AgendaItem.exists?(item.id)).to be(true)
      expect(old.reload.follow_up_at).to be_present

      job.notes.create!(tag: :rejected, occurred_at: Time.current)

      expect(booking.reload.follow_up_at).to be_nil
      expect(AgendaItem.find_by(id: item.id)).to be_nil
      expect(old.reload.follow_up_at).to be_nil
      expect(past.reload.follow_up_at).to be_present
      expect(job.notes.where(tag: :scheduled)).to include(booking)
    end

    it "does the same when they withdraw, and nothing on an offer" do
      withdrawn = user.job_applications.create!(company: "Withdrawn")
      booking = withdrawn.notes.create!(tag: :scheduled, follow_up_at: 4.days.from_now)
      offered = job.notes.create!(tag: :scheduled, follow_up_at: 4.days.from_now)

      withdrawn.notes.create!(tag: :withdrew, occurred_at: Time.current)
      job.notes.create!(tag: :offer, occurred_at: Time.current)

      expect(booking.reload.follow_up_at).to be_nil
      expect(offered.reload.follow_up_at).to be_present
    end
  end

  # A round falling through is not the process ending, and unlike a corrected
  # booking there is no window: a cancellation is not a correction.
  describe "the cancelled tag" do
    it "takes a booked future interview off the calendar however long ago it was booked", :aggregate_failures do
      past    = job.notes.create!(tag: :scheduled, follow_up_at: 2.days.ago)
      old     = travel_to(4.days.ago) { job.notes.create!(tag: :scheduled, follow_up_at: 10.days.from_now) }
      booking = job.notes.create!(tag: :scheduled, follow_up_at: 8.days.from_now.change(hour: 8, min: 0))
      item    = booking.follow_up_item
      expect(AgendaItem.exists?(item.id)).to be(true)
      expect(old.reload.follow_up_at).to be_present

      job.notes.create!(tag: :cancelled, occurred_at: Time.current)

      expect(booking.reload.follow_up_at).to be_nil
      expect(booking.follow_up_item).to be_nil
      expect(AgendaItem.find_by(id: item.id)).to be_nil
      expect(old.reload.follow_up_at).to be_nil
      expect(past.reload.follow_up_at).to be_present
      expect(job.notes.where(tag: :scheduled)).to include(booking)
      expect(job.reload.status).to eq("active")
    end

    it "is offered to the model as a tag it can pass" do
      expect(Buddy::Tools[:add_job_note][:args][:tag][:values]).to include(:cancelled)
    end
  end

  # A booked interview is a different animal from a chase: the date on the note
  # is the appointment itself, so it goes on the calendar as a timed event
  # rather than as a task called "Follow up".
  describe "the scheduled tag" do
    it "writes the interview onto the agenda as an event, an hour long unless told" do
      at = 3.days.from_now.change(hour: 14, min: 0)
      timed = job.notes.create!(tag: :scheduled, follow_up_at: at, duration_minutes: 45)
      other = user.job_applications.create!(company: "Other")
      untimed = other.notes.create!(tag: :scheduled, follow_up_at: at + 1.day)

      item = timed.follow_up_item
      expect(item.kind).to eq("event")
      expect(item.end_at).to be_within(1.second).of(at + 45.minutes)
      expect(untimed.follow_up_item.end_at).to be_within(1.second).of(at + 1.day + 1.hour)
    end

    it "still writes an ordinary follow-up as a task with no end" do
      note = job.notes.create!(tag: :heard_back, follow_up_at: 2.days.from_now)

      item = note.follow_up_item
      expect(item.kind).to eq("task")
      expect(item.end_at).to be_nil
    end

    # The row says what is OWED. "Follow up: Acme" against a take-home says
    # nothing about what the task is, which is the whole point of the tag -
    # `BALL_IN_COURT` is the one table both this and the board's strip read.
    it "names what is owed, for every tag that is owed something" do
      names = JobNote::BALL_IN_COURT.keys.map { |tag|
        job.notes.create!(tag: tag, body: "x", follow_up_at: 2.days.from_now).follow_up_item.name
      }

      expect(names).to eq([
        "Send availability: Acme",
        "Take-home to do: Acme",
        "Answer the offer: Acme",
        "Reply to them: Acme",
        "Reply to them: Acme",
      ])
    end

    it "falls back to a plain chase when the next move is theirs" do
      note = job.notes.create!(tag: :responded, body: "Wrote back", follow_up_at: 2.days.from_now)

      expect(note.follow_up_item.name).to eq("Follow up: Acme")
    end

    # Re-tagging has to convert the row it already wrote. Leaving an event
    # wearing a task's fields is how one ends up on the calendar with no end.
    it "converts the agenda row when the tag changes" do
      note = job.notes.create!(tag: :heard_back, follow_up_at: 2.days.from_now)
      note.update!(tag: :scheduled)

      item = note.reload.follow_up_item
      expect(item.kind).to eq("event")
      expect(item.end_at).to be_present

      note.update!(tag: :heard_back)

      item = note.reload.follow_up_item
      expect(item.kind).to eq("task")
      expect(item.end_at).to be_nil
    end
  end

  describe "settling the application" do
    it "settles the job from the newest note's tag", :aggregate_failures do
      { rejected: "rejected", offer: "offer", withdrew: "closed", interview: "active" }.each do |tag, status|
        application = user.job_applications.create!(company: "Acme #{tag}")
        application.notes.create!(body: "x", tag: tag)
        expect(application.reload.status).to eq(status), tag.to_s
      end
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

    it "drops ones on an application that is over, notes with none, and anyone else's" do
      job.notes.create!(body: "Just a thought")
      over = user.job_applications.create!(company: "Over")
      over.notes.create!(body: "Chase", follow_up_at: 2.days.from_now)
      over.update!(status: :rejected)
      theirs = create(:user).job_applications.create!(company: "Theirs")
      theirs.notes.create!(body: "Chase", follow_up_at: 2.days.from_now)

      expect(described_class.follow_ups_for(user)).to be_empty
    end

    describe "due_now" do
      # Pinned to midday, or "an hour from now" is tomorrow late in the evening.
      it "is the missed and the due-today, not the ones still ahead" do
        travel_to(user.parse_time("2026-09-10 12:00")) do
          missed = job.notes.create!(body: "Last week", follow_up_at: 6.days.ago)
          today  = job.notes.create!(body: "This evening", follow_up_at: 1.hour.from_now)
          job.notes.create!(body: "Friday", follow_up_at: 3.days.from_now)

          due = described_class.follow_ups_for(user).due_now(user)

          expect(due.map(&:id)).to eq([missed.id, today.id])
        end
      end

      # The end of UTC's day is 6pm in MDT, so a follow-up due later that same
      # evening must still count as due now.
      it "reads the end of THEIR day, not of UTC" do
        at = Time.utc(2026, 9, 10, 23, 30)  # 5:30pm MDT, and past UTC's evening
        tonight = job.notes.create!(body: "Tonight", follow_up_at: Time.utc(2026, 9, 11, 2))

        due = described_class.follow_ups_for(user).due_now(user, at)

        expect(due.map(&:id)).to include(tonight.id)
      end
    end
  end

  # A request for new times lands as its own note, and the booking it cancels
  # lives on the earlier `scheduled` one.
  describe "an availability request arriving on a booked application" do
    let!(:booking) { job.notes.create!(tag: :scheduled, follow_up_at: 5.days.from_now) }

    it "takes the interview off the calendar and keeps the note, because it was still booked" do
      item_id = booking.reload.agenda_item_id
      expect(item_id).to be_present

      job.notes.create!(tag: :availability, body: "Please send more times")

      expect(booking.reload.follow_up_at).to be_nil
      expect(booking.agenda_item_id).to be_nil
      expect(booking.tag).to eq("scheduled")
      expect(AgendaItem.find_by(id: item_id)).to be_nil
    end

    it "does the same when an arriving note is retagged into one" do
      note = job.notes.create!(tag: :note, body: "Olivia can no longer meet on the 24th")

      note.update!(tag: :availability)

      expect(booking.reload.follow_up_at).to be_nil
    end

    # An interview that already happened is history. A request for times weeks
    # later is about the next round.
    it "leaves a booking that has already been and gone" do
      past = job.notes.create!(tag: :scheduled, follow_up_at: 5.days.ago)

      job.notes.create!(tag: :availability, body: "Please send more times")

      expect(past.reload.follow_up_at).to be_present
    end

    # Retagging an earlier arrival to `availability` must not reach FORWARDS to
    # the booking made in answer to it.
    it "leaves a booking made after the request it answers" do
      arrival = job.notes.create!(tag: :interview, occurred_at: 2.hours.ago)
      picked  = job.notes.create!(tag: :scheduled, follow_up_at: 3.days.from_now)

      arrival.update!(tag: :availability)

      expect(picked.reload.follow_up_at).to be_present
    end

    it "still reaches a booking made before it" do
      booked = job.notes.create!(
        tag: :scheduled, follow_up_at: 3.days.from_now, occurred_at: 2.hours.ago,
      )

      job.notes.create!(tag: :availability, body: "Please send more times")

      expect(booked.reload.follow_up_at).to be_nil
    end
  end

  describe "a booking answering a request for times" do
    let!(:chase) {
      job.notes.create!(tag: :availability, follow_up_at: 4.days.from_now, occurred_at: 1.hour.ago)
    }

    it "takes the Send availability task off the calendar" do
      item_id = chase.reload.agenda_item_id
      expect(item_id).to be_present

      job.notes.create!(tag: :scheduled, follow_up_at: 4.days.from_now)

      expect(chase.reload.follow_up_at).to be_nil
      expect(AgendaItem.find_by(id: item_id)).to be_nil
    end

    it "leaves a request for times that came after the booking" do
      job.notes.create!(tag: :scheduled, follow_up_at: 4.days.from_now, occurred_at: 2.hours.ago)

      expect(chase.reload.follow_up_at).to be_present
    end

    it "leaves another application's request alone" do
      other = user.job_applications.create!(company: "Globex")
      theirs = other.notes.create!(tag: :availability, follow_up_at: 4.days.from_now, occurred_at: 1.hour.ago)

      job.notes.create!(tag: :scheduled, follow_up_at: 4.days.from_now)

      expect(theirs.reload.follow_up_at).to be_present
    end
  end

  # A correction filed minutes after a booking supersedes it. `next_interview_at`
  # reads the earliest standing booking, so the withdrawn note must lose its date.
  describe "a corrected booking landing behind the first one" do
    let!(:booking) { job.notes.create!(tag: :scheduled, follow_up_at: 3.days.from_now) }

    it "takes the superseded interview off the calendar and leaves the board on the corrected time" do
      item_id = booking.reload.agenda_item_id
      expect(item_id).to be_present

      correction = job.notes.create!(tag: :scheduled, follow_up_at: 10.days.from_now)

      expect(booking.reload.follow_up_at).to be_nil
      expect(AgendaItem.find_by(id: item_id)).to be_nil
      expect(correction.reload.follow_up_at).to be_present
      expect(correction.agenda_item_id).to be_present
      expect(job.reload.next_interview_at).to be_within(1.minute).of(10.days.from_now)
    end

    # The half that stops this from cancelling real meetings. Two rounds booked
    # a week apart are also two future `scheduled` notes, and there is nothing
    # in the rows themselves to tell that pair from a retraction - only how
    # close together they were filed.
    it "leaves a booking filed longer ago than the correction window" do
      old = travel_to((described_class::BOOKING_CORRECTION_WINDOW + 1.hour).ago) {
        job.notes.create!(tag: :scheduled, follow_up_at: 4.days.from_now)
      }

      job.notes.create!(tag: :scheduled, follow_up_at: 10.days.from_now)

      expect(old.reload.follow_up_at).to be_present
    end

    it "leaves an interview that already happened" do
      past = job.notes.create!(tag: :scheduled, follow_up_at: 5.days.ago)

      job.notes.create!(tag: :scheduled, follow_up_at: 10.days.from_now)

      expect(past.reload.follow_up_at).to be_present
    end

    # A booking moved UP is a correction however old the one it replaces.
    describe "a booking that moves EARLIER than one already standing" do
      # Absolute, because the fixture is filed from two days ago and a relative
      # `from_now` inside the travel block would move with it.
      let(:friday)    { 6.days.from_now }
      let(:wednesday) { 4.days.from_now }

      def filed_two_days_ago(at)
        travel_to((described_class::BOOKING_CORRECTION_WINDOW + 1.day).ago) {
          job.notes.create!(tag: :scheduled, follow_up_at: at)
        }
      end

      it "withdraws the later one however long ago it was filed, leaving the earlier as next" do
        old = filed_two_days_ago(friday)

        job.notes.create!(tag: :scheduled, follow_up_at: wednesday)

        expect(old.reload.follow_up_at).to be_nil
        expect(job.reload.next_interview_at).to be_within(1.minute).of(wednesday)
      end

      # The other direction is still a second round, so the window is still
      # what decides it.
      it "leaves an older booking that comes BEFORE the new one" do
        old = filed_two_days_ago(wednesday)

        job.notes.create!(tag: :scheduled, follow_up_at: friday)

        expect(old.reload.follow_up_at).to be_present
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

    it "takes the task back off when the follow-up is cleared or the note deleted" do
      cleared = job.notes.create!(body: "Chase them", follow_up_at: 3.days.from_now)
      deleted = job.notes.create!(body: "Chase again", follow_up_at: 4.days.from_now)

      cleared.update!(follow_up_at: nil)
      deleted.destroy!

      expect(cleared.reload.agenda_item_id).to be_nil
      expect(AgendaItem.count).to be_zero
    end

    it "carries only the link when the note had no body" do
      note = job.notes.create!(tag: :interview, follow_up_at: 3.days.from_now)

      expect(AgendaItem.find(note.reload.agenda_item_id).notes).to eq(job.interview_url)
    end

    it "writes nothing when there is no follow-up" do
      note = job.notes.create!(body: "Just a thought")

      expect(note.agenda_item_id).to be_nil
      expect(AgendaItem.count).to be_zero
    end

    # A calendar name is typed by a person, so stray case and whitespace still match.
    it "goes on the Tasks calendar, found through stray case and whitespace" do
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

  # The interview exists twice over, deliberately: the note's own row and the
  # company's invite, synced in from the calendar it was sent to. The invite
  # goes back out to the organizer when it is edited, so nothing of the note's
  # is written into it.
  describe "an interview that is also a calendar invite" do
    let(:google) { user.agendas.create!(name: "rocco@example.com", source: :google) }
    let(:at) { 3.days.from_now.change(hour: 11, min: 0, sec: 0) }

    def invite(name, start_at: at, uid: "evt-1")
      google.agenda_items.create!(
        name: name, kind: :event, start_at: start_at, end_at: start_at + 1.hour,
        status: :confirmed, external_uid: uid
      )
    end

    it "writes its own row beside the invite, whichever lands first, and leaves the invite alone" do
      item = invite("Technical Interview Acme")
      note = job.notes.create!(body: "Confirmed for 11am.", tag: :scheduled, follow_up_at: at)
      expect(note.reload.agenda_item_id).not_to eq(item.id)
      expect(item.reload.name).to eq("Technical Interview Acme")
      expect(item.notes).to be_blank

      later = job.notes.create!(tag: :scheduled, follow_up_at: at + 1.day)
      mine = later.reload.agenda_item_id
      invite("Technical Interview Acme", start_at: at + 1.day, uid: "evt-2")
      expect(later.reload.agenda_item_id).to eq(mine)
      expect(AgendaItem.find_by(id: mine)).to be_present
    end

    # The notes field of an invite is its DESCRIPTION, which the event writer
    # pushes back to Google and every attendee reads.
    it "never writes into a row that came from a calendar" do
      item = invite("Technical Interview Acme")
      note = job.notes.create!(tag: :scheduled, follow_up_at: at)
      note.update_columns(agenda_item_id: item.id)

      note.update!(body: "Ask about the team")

      expect(item.reload.notes).to be_blank
      expect(note.reload.agenda_item_id).not_to eq(item.id)
      expect(note.follow_up_item.notes).to include("Ask about the team")
    end
  end

  describe "what the agenda row says" do
    let(:at) { 3.days.from_now.change(hour: 11, min: 0, sec: 0) }

    it "leads the notes with a link to the application's page" do
      note = job.notes.create!(body: "Confirmed for 11am.", tag: :scheduled, follow_up_at: at)

      notes = note.reload.follow_up_item.notes
      expect(notes).to start_with(job.interview_url)
      expect(notes).to end_with("Confirmed for 11am.")
    end

    # A beat with nothing typed under it still earns the link: the tag on its
    # own is what put the row there.
    it "carries the link on its own when the beat said nothing, and on a chase too" do
      bare = job.notes.create!(tag: :scheduled, follow_up_at: at)
      chase = job.notes.create!(body: "Chase them", tag: :heard_back, follow_up_at: at + 1.day)

      expect(bare.reload.follow_up_item.notes).to eq(job.interview_url)
      expect(chase.reload.follow_up_item.notes).to start_with(job.interview_url)
    end

    # The brief is written off this row, so the tail of a long message (who is
    # joining, what it is about) has to survive.
    it "carries the whole message, however long it is" do
      said = "Hi Rocco,\n\n#{"Agenda line. " * 80}\n\nJoining you: Erik Brown."
      note = job.notes.create!(body: said, tag: :scheduled, follow_up_at: at)

      notes = note.reload.follow_up_item.notes
      expect(notes).to include("Joining you: Erik Brown.")
      expect(notes).not_to include("...")
      expect(notes).not_to include("\u2026")
    end

    # Ten lines into an invitation, under the organiser and the guest list, is
    # where the only thing worth tapping lives.
    it "lifts the link to join above everything else" do
      said = "Aledade - Phone Interview\n\nJoin with Google Meet\nhttps://meet.google.com/vhf-auiw-nhq?hs=224\n\nOrganizer"
      note = job.notes.create!(body: said, tag: :scheduled, follow_up_at: at)

      notes = note.reload.follow_up_item.notes
      expect(notes).to start_with("Join: https://meet.google.com/vhf-auiw-nhq?hs=224")
      expect(notes).to include(job.interview_url)
      expect(notes).to include("Join with Google Meet")
    end

    # Every link in an invitation is not the one to tap - the board, the
    # calendar's own "view event", the dial-in page.
    it "lifts nothing when the beat names no meeting" do
      note = job.notes.create!(body: "Reply at https://calendar.google.com/calendar/event?eid=1", tag: :scheduled, follow_up_at: at)

      expect(note.reload.follow_up_item.notes).to start_with(job.interview_url)
    end
  end

  describe "the one line the timeline reads" do
    it "is the summary when something wrote one" do
      note = job.notes.create!(
        tag:          :scheduled,
        occurred_at:  1.hour.ago,
        follow_up_at: 2.days.from_now,
        summary:      "Hiring manager round booked for Tue 3pm with Erik Brown",
        body:         "Hi Rocco,\n\nThanks for providing your availability!",
      )

      expect(note.headline).to eq("Hiring manager round booked for Tue 3pm with Erik Brown")
    end

    # A greeting is the first line about as often as not, and the date is
    # already beside it on the row.
    it "skips the greeting and takes the first line that says something" do
      note = job.notes.create!(
        tag:         :note,
        occurred_at: 1.hour.ago,
        body:        "Hi Rocco,\n\nWe would like to move you to a take-home.\n\nBest,\nDana",
      )

      expect(note.headline).to eq("We would like to move you to a take-home.")
    end

    it "falls back to the tag when the beat has no words at all" do
      note = job.notes.create!(tag: :applied, occurred_at: 1.hour.ago)

      expect(note.headline).to eq("Applied")
    end

    # An arrow that opens onto the same sentence again is a control that does
    # nothing, so a one-line note does not get one.
    # An arrow that opens onto the same sentence again is a control that does
    # nothing, so a one-line note does not get one.
    it "says whether there is more to open than the line itself" do
      one_line = job.notes.create!(tag: :note, occurred_at: 1.hour.ago, body: "Left a voicemail.")
      message = job.notes.create!(
        tag:         :note,
        occurred_at: 1.hour.ago,
        body:        "Hi Rocco,\n\nWe would like to move you to a take-home.\n\nBest,\nDana",
      )

      expect(one_line.headline).to eq("Left a voicemail.")
      expect(one_line.more_to_read?).to be(false)
      expect(message.more_to_read?).to be(true)
    end
  end

  describe "how it went" do
    let(:call) {
      job.notes.create!(tag: :recruiter_call, occurred_at: 1.hour.ago, body: "Spoke to Dana.")
    }

    it "is only asked about a conversation he was in" do
      expect(call).to be_conversation
      expect(job.notes.create!(tag: :acknowledged, occurred_at: 1.hour.ago)).not_to be_conversation
    end

    # Half-rated is ordinary, and the blank must not read as a zero.
    it "averages only the questions he answered, and is unrated rather than zero with none", :aggregate_failures do
      expect(call).not_to be_rated
      expect(call.sentiment).to eq({})
      expect(call.sentiment_average).to be_nil

      call.update!(did_well: 9)
      expect(call).to be_rated
      expect(call.sentiment).to eq(did_well: 9)
      expect(call.sentiment_average).to eq(9.0)

      call.update!(did_well: 8, liked_them: 6)
      expect(call.sentiment).to eq(did_well: 8, liked_them: 6)
      expect(call.sentiment_average).to eq(7.0)
    end

    it "refuses a score off the scale" do
      call.did_well = 11

      expect(call).not_to be_valid
      expect(call.errors[:did_well]).to be_present
    end

    it "takes the bottom of the scale, which is not the same as blank" do
      call.update!(did_well: 0)

      expect(call).to be_rated
      expect(call.sentiment_average).to eq(0.0)
    end

    # A range input always submits something, so the form's bottom notch sits
    # below the scale and means UNRATED. Without this, correcting the BODY of an
    # interview beat would stamp a score on it that he never gave.
    # A range input always submits something, so the form's bottom notch sits
    # below the scale and means UNRATED, as does anything a browser clamps below it.
    it "reads anything below the scale as no answer at all" do
      call.update!(did_well: JobNote::SENTIMENT_UNRATED, liked_them: 7)
      expect(call.reload.did_well).to be_nil
      expect(call.sentiment).to eq(liked_them: 7)

      call.update!(did_well: -4, liked_them: nil)
      expect(call.reload.did_well).to be_nil
      expect(call).not_to be_rated
    end
  end

  # The Fitness cell on the dashboard is pushed, never polled, so a logged
  # application has to announce itself.
  describe "the dashboard count" do
    before { allow_any_instance_of(User).to receive(:me?).and_return(true) }

    it "rebroadcasts the fitness cell when an application is logged" do
      expect(FitnessBroadcast).to receive(:broadcast)

      job.notes.create!(tag: :applied, occurred_at: Time.current)
    end

    it "stays quiet for every other beat of an application" do
      expect(FitnessBroadcast).not_to receive(:broadcast)

      job.notes.create!(tag: :interview, occurred_at: Time.current)
      job.notes.create!(tag: :rejected, occurred_at: Time.current)
    end

    # The cell is one person's. Somebody else's board does not touch it.
    it "stays quiet for somebody else's board" do
      allow_any_instance_of(User).to receive(:me?).and_return(false)
      expect(FitnessBroadcast).not_to receive(:broadcast)

      job.notes.create!(tag: :applied, occurred_at: Time.current)
    end
  end
end
