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

      expect(job.reload.engagement_depth).to eq(4)
      expect(job.engagement_label).to eq("got a take-home")
    end

    # A round falling through does not un-reach the rung it fell from, and the
    # label stays true while they rebook.
    it "keeps a cancelled booking at its booking's rung" do
      job.notes.create!(tag: :scheduled, occurred_at: 4.days.ago, follow_up_at: 3.days.ago)
      job.notes.create!(tag: :cancelled, occurred_at: 2.days.ago)

      expect(job.reload.engagement_depth).to eq(2)
      expect(job.engagement_label).to eq("got to a booking")
    end

    it "leaves out one that has stopped being live" do
      job.notes.create!(tag: :interview, occurred_at: 2.days.ago)
      job.update!(status: :rejected)

      expect(JobApplication.in_play_for(user)).to be_empty
    end

    it "keeps an offer, which is live and the top of the ladder" do
      job.notes.create!(tag: :offer, occurred_at: 1.day.ago)

      expect(job.reload.status).to eq("offer")
      expect(JobApplication.in_play_for(user).map(&:engagement_label)).to eq(["got an offer"])
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
      stale.notes.create!(tag: :scheduled, occurred_at: 8.days.ago, follow_up_at: 2.days.from_now)
      fresh = user.job_applications.create!(company: "Bluestaq")
      fresh.notes.create!(tag: :availability, occurred_at: 1.day.ago)

      standing = JobApplication.in_play_for(user)

      expect(standing.map(&:company)).to eq(%w[iCapital Bluestaq Neighbor])
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
end
