require "rails_helper"

# The board already paints "Waiting on you" at the top of the interviews page,
# and that page was the only place it was ever visible. Byte is where the day is
# read, so an availability request could sit for days unless somebody went
# looking for it.
RSpec.describe Buddy::JobWaiting do
  let(:user) { create(:user) }
  let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }
  let(:job) { user.job_applications.create!(company: "Reserv", role: "Staff Engineer") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def alert
    BuddyAlert.open_for(user, described_class.key_for(job.id))
  end

  describe "a beat that is his to answer" do
    it "raises one, naming what is owed and linking the application" do
      job.notes.create!(tag: :availability, occurred_at: 1.hour.ago)

      expect(alert.body).to eq("Send availability: [Reserv — Staff Engineer](#{job.interview_url})")
      expect(WebPushNotifications).to have_received(:send_to_byte).once
    end

    # The four tags are one table, `JobNote::BALL_IN_COURT`, and the alert says
    # whichever of them it is rather than "something is outstanding".
    it "says which of the four it is" do
      JobNote::BALL_IN_COURT.each do |tag, owed|
        row = user.job_applications.create!(company: "Acme #{tag}")
        row.notes.create!(tag: tag, occurred_at: 1.hour.ago)

        open = BuddyAlert.open_for(user, described_class.key_for(row.id))
        expect(open.body).to start_with("#{owed}:")
      end
    end

    it "leaves a beat that is theirs alone" do
      job.notes.create!(tag: :acknowledged, occurred_at: 1.hour.ago)

      expect(alert).to be_nil
      expect(ByteMessage.count).to be_zero
    end
  end

  # They clear separately: answering an offer at one company says nothing about
  # the availability another is waiting on.
  describe "one per application" do
    it "keeps two companies apart" do
      other = user.job_applications.create!(company: "Initech")
      job.notes.create!(tag: :availability, occurred_at: 1.hour.ago)
      other.notes.create!(tag: :take_home, occurred_at: 1.hour.ago)

      expect(BuddyAlert.status_open.count).to eq(2)
    end

    # The key is stable per row, so a second beat of his to answer rewrites the
    # bubble that row already owns.
    it "rewrites the one bubble when a second beat of his lands" do
      job.notes.create!(tag: :availability, occurred_at: 2.hours.ago)

      expect { job.notes.create!(tag: :take_home, occurred_at: 1.hour.ago) }
        .not_to change(BuddyAlert, :count)
      expect(alert.body).to start_with("Take-home to do:")
      expect(alert.raised_count).to eq(2)
    end
  end

  describe "it stops standing" do
    before { job.notes.create!(tag: :availability, occurred_at: 2.hours.ago) }

    it "clears when the company takes the next move" do
      job.notes.create!(tag: :scheduled, occurred_at: 1.hour.ago, follow_up_at: 3.days.from_now)

      expect(alert).to be_nil
      expect(BuddyAlert.last).to be_status_resolved
    end

    # The words it opened with are the honest record - what was owed is still
    # what was owed.
    it "keeps its own words on the way out" do
      job.notes.create!(tag: :responded, occurred_at: 1.hour.ago)

      expect(BuddyAlert.last.body).to start_with("Send availability:")
    end

    it "clears when the application is settled" do
      job.notes.create!(tag: :rejected, occurred_at: 1.hour.ago)

      expect(alert).to be_nil
    end

    # A retag is the ordinary repair, and the beat it was is the beat it is.
    it "clears when the beat is retagged to one of theirs" do
      job.notes.last.update!(tag: :heard_back)
      expect(alert).to be_present

      job.notes.last.update!(tag: :acknowledged)
      expect(alert).to be_nil
    end

    it "clears when the beat is deleted" do
      job.notes.last.destroy!

      expect(alert).to be_nil
    end
  end

  # The note's own `after_commit` runs on a destroy too, and the row can be gone
  # by the time it does.
  it "says nothing for an application that no longer exists" do
    expect(described_class.sync!(0)).to be_nil
    expect { job.destroy! }.not_to raise_error
  end
end
