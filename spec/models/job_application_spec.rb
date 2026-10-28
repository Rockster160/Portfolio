require "rails_helper"

RSpec.describe JobApplication do
  let(:user) { create(:user) }

  it "gives every application a colour without being asked" do
    job = user.job_applications.create!(company: "Acme")

    expect(job.color).to match(/\A#[0-9a-f]{6}\z/i)
  end

  it "keeps a colour that was chosen" do
    job = user.job_applications.create!(company: "Acme", color: "#123456")

    expect(job.color).to eq("#123456")
  end

  it "reads as company and role together" do
    expect(user.job_applications.new(company: "Acme", role: "Staff").label).to eq("Acme — Staff")
    expect(user.job_applications.new(company: "Acme").label).to eq("Acme")
  end

  it "falls back to initials when there is no logo" do
    expect(user.job_applications.new(company: "Acme").initials).to eq("A")
    expect(user.job_applications.new(company: "Big Corp").initials).to eq("BC")
  end

  # The column takes any icon reference the shared IconPool speaks, which is
  # the same set a chore's icon holds. Shape isn't validated — over-narrowing
  # it is what stopped an emoji going in — only size, for the one shape that
  # can run away with itself.
  it "takes every shape an icon reference comes in" do
    %w[🏢 ti-building hicon:12 data:image/png;base64,AAAA].each do |ref|
      job = user.job_applications.new(company: "Acme", logo: ref)

      expect(job).to be_valid, "expected #{ref} to be allowed"
    end
  end

  it "refuses a logo bigger than the ceiling" do
    job = user.job_applications.new(company: "Acme", logo: "d" * (JobApplication::MAX_LOGO_BYTES + 1))

    expect(job).not_to be_valid
    expect(job.errors[:logo]).to be_present
  end

  describe "the live scope" do
    it "is everything that hasn't ended" do
      active   = user.job_applications.create!(company: "A", status: :active)
      offer    = user.job_applications.create!(company: "B", status: :offer)
      user.job_applications.create!(company: "C", status: :rejected)
      user.job_applications.create!(company: "D", status: :closed)

      expect(user.job_applications.live.pluck(:id)).to contain_exactly(active.id, offer.id)
    end
  end

  describe "touch_activity!" do
    it "tracks the newest note's own timestamp, not when it was typed" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(body: "Applied", occurred_at: 10.days.ago)
      job.notes.create!(body: "Call", occurred_at: 2.days.ago)

      job.touch_activity!

      expect(job.reload.last_activity_at).to be_within(5.seconds).of(2.days.ago)
    end
  end

  describe "#jobhunt_url" do
    it "is nothing at all until the row knows its local id" do
      expect(user.job_applications.create!(company: "Acme").jobhunt_url).to be_nil
    end

    it "points at the job's page in the local hunter" do
      job = user.job_applications.create!(company: "Acme", jobhunt_job_id: 631)

      expect(job.jobhunt_url).to eq("http://localhost:8790/jobs/631")
    end
  end

  describe "#merge_with!" do
    let(:receipt_at) { Time.zone.parse("2026-09-17 16:41:31") }
    # jobhunt's row: the role, the listing, the moment it says it submitted.
    let(:keep) {
      user.job_applications.create!(company: "Workstream", role: "Staff Engineer", url: "https://x.test/1")
    }
    # The row opened off the ATS receipt, seconds later, knowing only the company.
    let(:drop) { user.job_applications.create!(company: "Workstream", source: "Workstream") }

    def applied_at(at)
      keep.notes.create!(tag: :applied, occurred_at: at)
    end

    def receipt!
      drop.notes.create!(tag: :acknowledged, occurred_at: receipt_at, body: "Thank you for applying")
    end

    it "moves every note across and deletes the other row" do
      applied = applied_at(receipt_at - 10.minutes)
      receipt = receipt!

      keep.merge_with!(drop)

      expect(JobApplication.exists?(drop.id)).to be(false)
      expect(JobNote.where(id: [applied.id, receipt.id]).pluck(:job_application_id).uniq).to eq([keep.id])
      expect(keep.reload.last_activity_at).to eq(receipt_at)
    end

    it "keeps the row jobhunt recorded, whichever side it is merged from" do
      keep.notes.create!(tag: :applied, source: "jobhunt", occurred_at: receipt_at)
      receipt!

      expect(drop.merge_with!(keep)).to eq(keep)
      expect(JobApplication.exists?(keep.id)).to be(true)
      expect(JobApplication.exists?(drop.id)).to be(false)
      expect(keep.notes.reload.map(&:tag)).to contain_exactly("applied", "acknowledged")
    end

    # The one pointer nothing else can reconstruct: jobhunt remembers the board
    # row by id, and a merge that loses the local id strands the local page even
    # though the surviving row is the one jobhunt now talks to.
    it "carries the local job id over to the row that survives" do
      drop.update!(jobhunt_job_id: 463)
      keep.notes.create!(tag: :applied, source: "jobhunt", occurred_at: receipt_at)

      keep.merge_with!(drop)

      expect(keep.reload.jobhunt_job_id).to eq(463)
      expect(keep.jobhunt_url).to eq("http://localhost:8790/jobs/463")
    end

    it "keeps its own local id when both rows have one" do
      keep.update!(jobhunt_job_id: 182)
      drop.update!(jobhunt_job_id: 463)

      keep.merge_with!(drop)

      expect(keep.reload.jobhunt_job_id).to eq(182)
    end

    it "keeps the row it was called on when neither was recorded by jobhunt" do
      expect(drop.merge_with!(keep)).to eq(drop)
      expect(JobApplication.exists?(keep.id)).to be(false)
    end

    it "keeps the row it was called on when both were" do
      keep.notes.create!(tag: :applied, source: "jobhunt", occurred_at: receipt_at)
      drop.notes.create!(tag: :applied, source: "jobhunt", occurred_at: receipt_at)

      expect(drop.merge_with!(keep)).to eq(drop)
    end

    it "fills what this row is missing and keeps what it has" do
      drop.update!(role: "Something else", url: "https://x.test/2")

      keep.merge_with!(drop)

      expect(keep.reload.role).to eq("Staff Engineer")
      expect(keep.url).to eq("https://x.test/1")
      expect(keep.source).to eq("Workstream")
    end

    it "puts an applied that landed within the hour after the receipt five minutes before it" do
      applied = applied_at(receipt_at + 7.minutes + 20.seconds)
      receipt!

      keep.merge_with!(drop)

      expect(applied.reload.occurred_at).to eq(receipt_at - 5.minutes)
    end

    it "leaves an applied more than an hour after the receipt where it is" do
      applied = applied_at(receipt_at + 61.minutes)
      receipt!

      keep.merge_with!(drop)

      expect(applied.reload.occurred_at).to eq(receipt_at + 61.minutes)
    end

    it "never moves an applied that was already before the receipt" do
      applied = applied_at(receipt_at - 30.seconds)
      receipt!

      keep.merge_with!(drop)

      expect(applied.reload.occurred_at).to eq(receipt_at - 30.seconds)
    end

    it "measures from the EARLIEST receipt" do
      applied = applied_at(receipt_at + 20.minutes)
      receipt!
      keep.notes.create!(tag: :acknowledged, occurred_at: receipt_at + 10.minutes)

      keep.merge_with!(drop)

      expect(applied.reload.occurred_at).to eq(receipt_at - 5.minutes)
    end

    it "takes the status a settling beat implies, or the other row's when this one is only active" do
      drop.notes.create!(tag: :rejected, occurred_at: 1.minute.ago)

      expect(keep.merge_with!(drop).reload.status).to eq("rejected")

      other = user.job_applications.create!(company: "Workstream", status: :closed)
      live  = user.job_applications.create!(company: "Workstream")
      live.notes.create!(tag: :note, body: "hi", occurred_at: 1.minute.ago)

      expect(live.merge_with!(other).reload.status).to eq("closed")
    end

    it "refuses itself and someone else's row" do
      stranger = create(:user).job_applications.create!(company: "Workstream")

      expect { keep.merge_with!(keep) }.to raise_error(ArgumentError)
      expect { keep.merge_with!(stranger) }.to raise_error(ArgumentError)
      expect(JobApplication.exists?(stranger.id)).to be(true)
    end
  end

  # The few applications where something is genuinely happening, picked out of a
  # board that is mostly rows nobody ever answered.
  describe "an interview that has been and gone" do
    let(:job) { user.job_applications.create!(company: "Reserv") }

    it "is held once the slot has passed and nothing has been said" do
      job.notes.create!(tag: :scheduled, occurred_at: 3.days.ago, follow_up_at: 1.day.ago)

      expect(job.reload.next_interview_at).to be_nil
      expect(job.unreported_interview_at).to be_within(1.second).of(1.day.ago)
    end

    it "lets go once any beat lands after it" do
      job.notes.create!(tag: :scheduled, occurred_at: 3.days.ago, follow_up_at: 2.days.ago)
      job.notes.create!(tag: :note, body: "Went well", occurred_at: 1.day.ago)

      expect(job.reload.unreported_interview_at).to be_nil
    end

    it "does not count the scheduling note itself as having said something" do
      job.notes.create!(tag: :scheduled, occurred_at: 1.hour.ago, follow_up_at: 1.minute.ago)

      expect(job.reload.unreported_interview_at).to be_present
    end

    it "holds nothing while the slot is still ahead" do
      job.notes.create!(tag: :scheduled, occurred_at: 1.day.ago, follow_up_at: 2.days.from_now)

      expect(job.reload.unreported_interview_at).to be_nil
    end

    it "asks about the LAST one when two have passed" do
      job.notes.create!(tag: :scheduled, occurred_at: 9.days.ago, follow_up_at: 8.days.ago)
      job.notes.create!(tag: :note, body: "Round one done", occurred_at: 7.days.ago)
      job.notes.create!(tag: :scheduled, occurred_at: 6.days.ago, follow_up_at: 2.days.ago)

      expect(job.reload.unreported_interview_at).to be_within(1.second).of(2.days.ago)
    end

    # The call is logged from the moment it STARTED, so the write-up lands on
    # the booked time rather than after it. brightwheel's booking and the
    # recruiter call written up from it both read 11:00.
    it "lets go of a booking written up at exactly its slot" do
      slot = 3.hours.ago
      job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: slot)
      job.notes.create!(tag: :recruiter_call, occurred_at: slot, body: "Sounded keen")

      expect(job.reload.unreported_interview_at).to be_nil
    end

    # River's was stamped fifteen minutes ahead of the slot it was booked for.
    it "lets go of one written up in the hour before its slot" do
      slot = 3.hours.ago
      job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: slot)
      job.notes.create!(tag: :interview, occurred_at: slot - 15.minutes, body: "Went well")

      expect(job.reload.unreported_interview_at).to be_nil
    end

    # The leniency is for a write-up arriving around its own meeting, not for
    # one belonging to the round before it.
    it "still asks when the only conversation on the row predates the booking" do
      slot = 3.hours.ago
      job.notes.create!(tag: :interview, occurred_at: 9.days.ago, body: "Round one")
      job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: slot)

      expect(job.reload.unreported_interview_at).to be_within(1.second).of(slot)
    end
  end

  describe "the beat it expects next" do
    let(:job) { user.job_applications.create!(company: "Reserv") }

    it "opens on Applied with an empty timeline" do
      expect(job.expected_next_tag).to eq(:applied)
    end

    it "opens on the write-up once a booked slot has passed" do
      job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 1.hour.ago)

      expect(job.reload.expected_next_tag).to eq(:recruiter_call)
    end

    # Every conversation after the first one is an interview, and the rung the
    # row has reached already says which this is.
    it "opens on Interview once a recruiter call is behind it" do
      job.notes.create!(tag: :recruiter_call, occurred_at: 9.days.ago)
      job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 1.hour.ago)

      expect(job.reload.expected_next_tag).to eq(:interview)
    end

    it "does not reach for a conversation while the slot is still ahead" do
      job.notes.create!(tag: :scheduled, occurred_at: 1.day.ago, follow_up_at: 2.days.from_now)

      expect(job.reload.expected_next_tag).to eq(:note)
    end

    it "opens on Responded when a person on their side wrote last" do
      job.notes.create!(tag: :heard_back, occurred_at: 1.day.ago, body: "Are you still keen?")

      expect(job.reload.expected_next_tag).to eq(:responded)
    end

    it "falls back to a plain note" do
      job.notes.create!(tag: :applied, occurred_at: 2.days.ago)

      expect(job.reload.expected_next_tag).to eq(:note)
    end
  end

  describe "where you stand" do
    let(:job) { user.job_applications.create!(company: "Reserv") }

    it "has no rung until a person on their side moves" do
      job.notes.create!(tag: :applied, occurred_at: 2.days.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 2.days.ago)
      job.notes.create!(tag: :note, body: "job alert digest", occurred_at: 1.day.ago)

      expect(job.engagement_depth).to be_nil
      expect(job.engagement_label).to be_nil
      expect(JobApplication.in_play_for(user)).to be_empty
    end

    it "counts his own moves as nothing - interest is a thing THEY do" do
      job.notes.create!(tag: :responded, body: "Nudged them", occurred_at: 1.day.ago)

      expect(JobApplication.in_play_for(user)).to be_empty
    end

    it "takes the FURTHEST rung, not the latest beat" do
      job.notes.create!(tag: :take_home, occurred_at: 5.days.ago)
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago)

      expect(job.reload.engagement_depth).to eq(5)
      expect(job.engagement_label).to eq("Take-home")
    end

    # A round falling through does not un-reach the rung it fell from, and the
    # label stays true while they rebook.
    it "keeps a cancelled booking at its booking's rung" do
      job.notes.create!(tag: :scheduled, occurred_at: 4.days.ago, follow_up_at: 3.days.ago)
      job.notes.create!(tag: :cancelled, occurred_at: 2.days.ago)

      expect(job.reload.engagement_depth).to eq(3)
      expect(job.engagement_label).to eq("Scheduled")
    end

    it "leaves out one that has stopped being live" do
      job.notes.create!(tag: :interview, occurred_at: 2.days.ago)
      job.update!(status: :rejected)

      expect(JobApplication.in_play_for(user)).to be_empty
    end

    it "keeps an offer, which is live and the top of the ladder" do
      job.notes.create!(tag: :offer, occurred_at: 1.day.ago)

      expect(job.reload.status).to eq("offer")
      expect(JobApplication.in_play_for(user).map(&:engagement_label)).to eq(["Offer"])
    end

    it "reaches nobody else's board" do
      job.notes.create!(tag: :heard_back, occurred_at: 1.day.ago)

      expect(JobApplication.in_play_for(create(:user))).to be_empty
    end

    it "puts the deepest first, and the stalest last within a rung" do
      deep = user.job_applications.create!(company: "iCapital")
      deep.notes.create!(tag: :interview, occurred_at: 9.days.ago)
      # Created oldest-first on purpose: the order has to come off the beats,
      # and a row's own age would put these two the other way round.
      stale = user.job_applications.create!(company: "Neighbor")
      stale.notes.create!(tag: :availability, occurred_at: 8.days.ago)
      fresh = user.job_applications.create!(company: "Bluestaq")
      fresh.notes.create!(tag: :availability, occurred_at: 1.day.ago)

      standing = JobApplication.in_play_for(user)

      expect(standing.map(&:company)).to eq(%w[iCapital Bluestaq Neighbor])
    end

    # The "gone back and forth" half of a standing: ROUND TRIPS, not mails.
    describe "counting the round trips" do
      it "counts nothing off his own moves or a machine's receipt" do
        job.notes.create!(tag: :applied, occurred_at: 5.days.ago)
        job.notes.create!(tag: :acknowledged, occurred_at: 5.days.ago)
        job.notes.create!(tag: :responded, body: "Nudged them", occurred_at: 4.days.ago)

        expect(job.reload.interaction_count).to eq(0)
      end

      # The ask, the times he sent back and the confirmation that follows are
      # one thing happening, however many rows it leaves behind.
      it "counts the whole exchange that produces a booking as one" do
        job.notes.create!(tag: :availability, occurred_at: 5.days.ago)
        job.notes.create!(tag: :responded, body: "Sent availability", occurred_at: 4.days.ago)
        job.notes.create!(tag: :scheduled, occurred_at: 3.days.ago, follow_up_at: 2.days.from_now)
        job.notes.create!(tag: :note, body: "You are confirmed", occurred_at: 3.days.ago)

        expect(job.reload.interaction_count).to eq(1)
      end

      it "counts the booking and the call it booked separately" do
        job.notes.create!(tag: :availability, occurred_at: 6.days.ago)
        job.notes.create!(tag: :scheduled, occurred_at: 5.days.ago, follow_up_at: 3.days.ago)
        job.notes.create!(tag: :recruiter_call, occurred_at: 3.days.ago)

        expect(job.reload.interaction_count).to eq(2)
      end

      # A cancel and a rebook of the same meeting is a reschedule.
      it "counts the booking once however often it moves" do
        job.notes.create!(tag: :scheduled, occurred_at: 5.days.ago, follow_up_at: 1.day.ago)
        job.notes.create!(tag: :cancelled, occurred_at: 3.days.ago)
        job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 3.days.from_now)

        expect(job.reload.interaction_count).to eq(1)
      end

      # Two of these arrive for one meeting all the time: the organizer's
      # confirmation, then the correction half an hour later.
      it "counts a re-confirmation of a meeting still ahead of us as nothing" do
        job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 4.days.from_now)
        job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 5.days.from_now)

        expect(job.reload.interaction_count).to eq(1)
      end

      # The one that matters for a real board: the screen happened, nobody
      # wrote it up, and the second round still has to count.
      it "counts the next booking once the last meeting's time has passed" do
        job.notes.create!(tag: :scheduled, occurred_at: 8.days.ago, follow_up_at: 6.days.ago)
        job.notes.create!(tag: :availability, occurred_at: 2.days.ago)
        job.notes.create!(tag: :scheduled, occurred_at: 1.day.ago, follow_up_at: 3.days.from_now)

        expect(job.reload.interaction_count).to eq(2)
      end

      it "counts homework and an offer as rounds of their own" do
        job.notes.create!(tag: :take_home, occurred_at: 4.days.ago)
        job.notes.create!(tag: :offer, occurred_at: 1.day.ago)

        expect(job.reload.interaction_count).to eq(2)
      end

      # Reminders, calendar confirmations and an ATS re-sending its own
      # template all land as plain notes, and none of them is an exchange.
      it "counts nothing off the notes a timeline collects" do
        nudge = "Still waiting on your availability"
        job.notes.create!(tag: :availability, occurred_at: 4.days.ago)
        job.notes.create!(tag: :note, body: nudge, occurred_at: 3.days.ago)
        job.notes.create!(tag: :note, body: nudge, occurred_at: 2.days.ago)

        expect(job.reload.interaction_count).to eq(1)
      end

      it "counts an exchange nothing has come of yet as one round trip" do
        job.notes.create!(tag: :heard_back, body: "Luke wrote", occurred_at: 1.day.ago)

        expect(job.reload.interaction_count).to eq(1)
      end
    end

    # `last_activity_at` is the same answer only while every write path
    # remembers to touch it, and the strip says how long a thing has been
    # quiet - a stale column there is a sentence that is simply false.
    it "measures quiet from the beats, not from a column somebody has to maintain" do
      job.notes.create!(tag: :heard_back, occurred_at: 2.days.ago)
      job.update!(last_activity_at: 30.days.ago)

      expect(job.reload.engaged_at.to_date).to eq(2.days.ago.to_date)
    end

    # The same reading `JobNote.waiting_on_you_for` takes, off the last beat
    # whatever its tag - the two say whose move it is on one page.
    it "says whose move it is off the LAST beat" do
      job.notes.create!(tag: :availability, occurred_at: 2.days.ago)

      expect(job.reload.owed_now).to eq("Send availability")

      job.notes.create!(tag: :note, body: "Submitted my times", occurred_at: 1.day.ago)

      expect(job.reload.owed_now).to be_nil
    end
  end

  describe "an offer re-sent on a timer" do
    it "counts one round however many copies of it arrive" do
      job = user.job_applications.create!(company: "iCapital")
      job.notes.create!(tag: :applied, occurred_at: 9.days.ago)
      job.notes.create!(tag: :offer, occurred_at: 2.days.ago)
      job.notes.create!(tag: :offer, occurred_at: 1.day.ago)
      job.notes.create!(tag: :offer, occurred_at: 2.hours.ago)

      expect(job.reload.interaction_count).to eq(1)
      expect(job.engagement_label).to eq("Offer")
    end
  end

  # A recruiter coming to him first, on a job he never applied to.
  describe "being reached out to" do
    let(:job) { user.job_applications.create!(company: "Ichi") }

    before { job.notes.create!(tag: :reached_out, body: "I came across your background", occurred_at: 1.day.ago) }

    it "is a person on their side moving, with the reply his" do
      expect(job.reload.interaction_count).to eq(1)
      expect(job.engagement_depth).to eq(1)
      expect(job.owed_now).to eq("Reply to them")
      expect(JobApplication.silence_for(user)[:total]).to eq(0)
    end
  end

  # A machine re-sending something already on the timeline. Nothing happened,
  # so nothing on the board may read as though it did.
  describe "a reminder" do
    let(:job) { user.job_applications.create!(company: "iCapital") }

    before {
      job.notes.create!(tag: :offer, occurred_at: 3.days.ago)
      job.notes.create!(tag: :reminder, body: "Reminder: please sign", occurred_at: 1.hour.ago)
    }

    it "is not an interaction" do
      expect(job.reload.interaction_count).to eq(1)
      expect(job.engagement_label).to eq("Offer")
    end

    it "doesn't make a quiet row look active" do
      job.touch_activity!

      expect(job.reload.last_activity_at).to be_within(5.seconds).of(3.days.ago)
      expect(job.engaged_at).to be_within(5.seconds).of(3.days.ago)
    end

    it "leaves the beat it reminds about as the one whose move it is" do
      expect(job.reload.latest_beat).to be_offer
      expect(job.owed_now).to eq("Answer the offer")
      expect(JobNote.waiting_on_you_for(user).map(&:tag)).to eq(["offer"])
    end
  end

  describe "the silence" do
    it "counts an application a machine receipted and nobody answered" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 3.days.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 3.days.ago)
      job.notes.create!(tag: :note, body: "job alert digest", occurred_at: 1.day.ago)

      expect(JobApplication.silence_for(user)).to eq(total: 1, recent: 1)
    end

    it "counts his own nudge as nothing - a reply has to come from them" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 3.days.ago)
      job.notes.create!(tag: :responded, body: "Nudged them", occurred_at: 1.day.ago)

      expect(JobApplication.silence_for(user)[:total]).to eq(1)
    end

    it "drops one the moment a person on their side writes" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 3.days.ago)
      job.notes.create!(tag: :heard_back, occurred_at: 1.day.ago)

      expect(JobApplication.silence_for(user)).to eq(total: 0, recent: 0)
    end

    # A no is still an answer, which is what keeps the figure honest: the
    # engagement ladder leaves these two off because they settle the row.
    it "drops a rejection and a withdrawal" do
      JobNote::IMPLIED_STATUS.slice("rejected", "withdrew").each_key do |tag|
        job = user.job_applications.create!(company: "Reserv #{tag}")
        job.notes.create!(tag: :applied, occurred_at: 3.days.ago)
        job.notes.create!(tag: tag, occurred_at: 1.day.ago)
      end

      expect(JobApplication.silence_for(user)[:total]).to eq(0)
    end

    it "leaves an older one out of the month figure but in the total" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 3.months.ago)

      expect(JobApplication.silence_for(user)).to eq(total: 1, recent: 0)
    end

    # The row whose `applied` beat was never written: the timeline starts at the
    # receipt, and the receipt is the same day as the application.
    it "dates one with no applied beat from whatever it does have" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :acknowledged, occurred_at: 2.days.ago)

      expect(JobApplication.silence_for(user)).to eq(total: 1, recent: 1)
      expect(job.applied_at).to be_within(1.second).of(job.notes.first.occurred_at)
    end

    it "reaches nobody else's board" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 1.day.ago)

      expect(JobApplication.silence_for(create(:user))).to eq(total: 0, recent: 0)
    end
  end

  describe "how the whole application has felt" do
    let(:job) { user.job_applications.create!(company: "Reserv") }

    def call(at:, did_well: nil, liked_them: nil)
      job.notes.create!(
        tag:         :recruiter_call,
        occurred_at: at,
        body:        "Spoke to them.",
        did_well:    did_well,
        liked_them:  liked_them,
      )
    end

    it "averages each question across every conversation he rated" do
      call(at: 3.days.ago, did_well: 8, liked_them: 4)
      call(at: 1.day.ago, did_well: 6, liked_them: 6)

      expect(job.reload.sentiment).to eq(did_well: 7.0, liked_them: 5.0)
    end

    # The two come apart constantly - a screen he fumbled with people he would
    # happily work for - and that is the whole reason there are two of them.
    it "keeps the two apart rather than collapsing them into one number" do
      call(at: 1.day.ago, did_well: 2, liked_them: 10)

      expect(job.reload.sentiment).to eq(did_well: 2.0, liked_them: 10.0)
    end

    it "leaves out a question nobody has answered" do
      call(at: 1.day.ago, did_well: 7)

      expect(job.reload.sentiment).to eq(did_well: 7.0)
    end

    # The mean of the ANSWERS, not the mean of the two averages: weighting a
    # single company score to half the row is how one bad afternoon sinks a job
    # he otherwise likes.
    it "weighs every answer the same in the single figure" do
      call(at: 3.days.ago, did_well: 9)
      call(at: 2.days.ago, did_well: 9)
      call(at: 1.day.ago, did_well: 9, liked_them: 3)

      expect(job.reload.sentiment_average).to eq(7.5)
    end

    it "says nothing at all when he has rated nothing" do
      call(at: 1.day.ago)
      job.notes.create!(tag: :applied, occurred_at: 2.days.ago)

      expect(job.reload.sentiment).to eq({})
      expect(job.sentiment_average).to be_nil
    end
  end

  # THE PROCESS. Every search starts not knowing the rounds, so the list starts
  # as the four that are always there and becomes the company's own once they
  # say what theirs is.
  describe "the other names it answers to" do
    let(:job) { user.job_applications.create!(company: "iCapital") }

    it "takes one name per line and keeps them as typed" do
      job.known_as_lines = " Institutional Capital Network \n\naccurate.com\n"
      job.save!

      expect(job.reload.known_as).to eq(["Institutional Capital Network", "accurate.com"])
      expect(job.known_as_lines).to eq("Institutional Capital Network\naccurate.com")
    end

    it "keeps one of each name" do
      job.known_as_lines = "Accurate\naccurate\nSterling"

      expect(job.known_as).to eq(["Accurate", "Sterling"])
    end

    it "keeps the list to something a person typed" do
      job.known_as_lines = (1..30).map { |n| "Name #{n}" }.join("\n")

      expect(job.known_as.size).to eq(JobApplication::MAX_KNOWN_AS)
      expect(job.known_as.first.length).to be <= JobApplication::MAX_KNOWN_AS_NAME
    end

    # A domain catches everything that vendor sends from; a whole address
    # catches only itself, which is what to write down when the domain is
    # shared - a Gmail address a recruiter works out of.
    it "matches a sender by domain or in full" do
      job.update!(known_as: ["accurate.com", "alexis.salamon@example.test"])

      expect(job.known_sender?("InfoNeeded@Accurate.com")).to be(true)
      expect(job.known_sender?("alexis.salamon@example.test")).to be(true)
      expect(job.known_sender?("someone@example.test")).to be(false)
      expect(job.known_sender?("")).to be(false)
    end

    it "is not a sender just because the name reads like one" do
      job.update!(known_as: ["Accurate"])

      expect(job.known_sender?("infoneeded@accurate.com")).to be(false)
    end

    it "is listed as carrying other names only when it does" do
      job
      aliased = user.job_applications.create!(company: "Wildcat", known_as: ["wildcat.test"])

      expect(JobApplication.with_other_names.to_a).to eq([aliased])
    end
  end

  describe "the rubric" do
    let(:job) { user.job_applications.create!(company: "Acme") }

    def beat(tag, at)
      job.notes.create!(tag: tag, occurred_at: at)
    end

    it "starts as the standard steps, none of them answered" do
      expect(job.rubric_steps.map(&:name)).to eq(
        ["Applied", "Recruiter screen", "Hiring manager call", "Technical screen", "Onsite loop", "Offer"],
      )
      expect(job.rubric_steps).to all(satisfy { |step| !step.done? })
    end

    # The tick is read off the notes every time rather than written down when
    # one arrives, so a step's date is the date of the thing itself however
    # late it was written up.
    it "ticks a step off the beat that answered it, on the beat's own date" do
      beat(:applied, 3.weeks.ago)
      beat(:recruiter_call, 2.weeks.ago)

      steps = job.reload.rubric_steps
      expect(steps.map(&:done?)).to eq([true, true, false, false, false, false])
      expect(steps.first.done_at).to be_within(1.second).of(3.weeks.ago)
      expect(steps.first.by_hand).to be(false)
    end

    it "answers one step per beat, so each round ticks off its own interview" do
      job.rubric_lines = "Applied\nTeam call\nLive coding challenge\nCEO interview"
      job.save!
      beat(:interview, 2.days.ago)

      expect(job.reload.rubric_steps.map(&:done?)).to eq([false, true, false, false])
    end

    # Three of the standard steps are interviews, so the rounds come off one at
    # a time rather than all at once on the first one logged.
    it "ticks one standard interview round per interview logged" do
      beat(:interview, 2.weeks.ago)
      beat(:interview, 1.week.ago)

      expect(job.reload.rubric_steps.map(&:done?)).to eq([false, false, true, true, false, false])
    end

    it "works out what ticks a step off from what the step is called" do
      job.rubric_lines = "Applied\nRecruiter screen\nTake-home exercise\nFinal panel\nOffer\nReference check"
      job.save!

      expect(job.rubric.pluck("tag")).to eq(
        ["applied", "recruiter_call", "take_home", "interview", "offer", nil],
      )
    end

    it "takes the steps as they were pasted, bullets and numbering and all" do
      job.rubric_lines = "- 30m with the team\n2. Live coding\n* CEO, one hour\n\n"
      job.save!

      expect(job.rubric.pluck("name")).to eq(["30m with the team", "Live coding", "CEO, one hour"])
    end

    # Adding the two rounds a company has just named is not a reset of
    # everything already answered.
    it "keeps the tick on a step that still reads the same" do
      job.rubric_ticks = [0]
      job.save!
      answered = job.rubric_steps.first.done_at

      job.rubric_lines = "Applied\nRecruiter screen\nTake-home\nInterview\nOffer"
      job.save!

      expect(job.rubric_steps.first.done_at).to be_within(1.second).of(answered)
      expect(job.rubric_steps.map(&:name)).to include("Take-home")
    end

    it "goes back to the standard steps when the list is emptied" do
      job.rubric_lines = "Just the one"
      job.save!
      job.rubric_lines = ""
      job.save!

      expect(job.rubric_steps.map(&:name)).to eq(JobApplication::DEFAULT_RUBRIC)
    end

    it "ticks a step nothing on the timeline speaks for" do
      job.rubric_lines = "Reference check"
      job.save!
      job.rubric_ticks = [0]
      job.save!

      expect(job.rubric_steps.first.done?).to be(true)
      expect(job.rubric_steps.first.by_hand).to be(true)
    end

    it "clears a tick that was made by hand" do
      job.rubric_ticks = [0, 1]
      job.save!
      job.rubric_ticks = [0]
      job.save!

      expect(job.rubric_steps.map(&:done?)).to eq([true, false, false, false, false, false])
    end

    # The way to say an interview didn't happen is to delete the interview.
    it "cannot be talked out of a step the timeline answered" do
      beat(:applied, 1.week.ago)
      job.reload.rubric_ticks = []
      job.save!

      expect(job.reload.rubric_steps.first.done?).to be(true)
    end

    it "keeps the list to something a person typed" do
      job.rubric_lines = (1..40).map { |n| "Step #{n}" }.join("\n")
      job.save!

      expect(job.rubric.size).to eq(JobApplication::MAX_RUBRIC_STEPS)
      expect(job.rubric.first["name"].length).to be <= JobApplication::MAX_RUBRIC_NAME
    end

    it "keeps one step per name" do
      job.rubric_lines = "Interview\ninterview\nOffer"
      job.save!

      expect(job.rubric.pluck("name")).to eq(["Interview", "Offer"])
    end
  end
end
