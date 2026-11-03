require "rails_helper"

# An application waiting on him gets a `waiting` chip on Byte's strip until the
# ball is back in the company's court.
RSpec.describe Buddy::JobWaiting do
  let(:user) { create(:user) }
  let(:job) { user.job_applications.create!(company: "Reserv", role: "Staff Engineer") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def chip
    BackgroundProcess.where(user: user, key: described_class.key_for(job.id)).live.last
  end

  describe "a beat that is his to answer" do
    # `waiting` is the state the strip colours as asking for a person, sorts to
    # the front, and exempts from ageing out - so it stays until it is done.
    it "puts up a waiting chip linked to the application, never claiming to be in progress", :aggregate_failures do
      job.notes.create!(tag: :availability, occurred_at: 1.hour.ago)

      expect(chip).to be_waiting
      expect(chip).not_to be_running
      expect(chip).not_to be_stale
      expect(chip.name).to eq(JobNote::BALL_IN_COURT["availability"])
      expect(chip.links).to eq([{ "label" => "Reserv", "url" => job.interview_url }])
    end

    # The name is the whole chip and gets 20 characters.
    it "says which of the four it is, in the room it has" do
      JobNote::BALL_IN_COURT.each do |tag, owed|
        row = user.job_applications.create!(company: "Acme #{tag}")
        row.notes.create!(tag: tag, occurred_at: 1.hour.ago)

        drawn = BackgroundProcess.where(user: user, key: described_class.key_for(row.id)).live.last
        expect(drawn.name).to eq(owed)
        expect(owed.length).to be <= BackgroundProcess::MAX_NAME
      end
    end

    it "leaves a beat that is theirs alone" do
      job.notes.create!(tag: :acknowledged, occurred_at: 1.hour.ago)

      expect(chip).to be_nil
      expect(BackgroundProcess.count).to be_zero
    end
  end

  # They clear separately: answering an offer at one company says nothing about
  # the availability another is waiting on.
  describe "one per application" do
    it "keeps two companies apart" do
      other = user.job_applications.create!(company: "Initech")
      job.notes.create!(tag: :availability, occurred_at: 1.hour.ago)
      other.notes.create!(tag: :take_home, occurred_at: 1.hour.ago)

      expect(BackgroundProcess.live.count).to eq(2)
    end

    it "rewrites the one chip when a second beat of his lands" do
      job.notes.create!(tag: :availability, occurred_at: 2.hours.ago)

      expect { job.notes.create!(tag: :take_home, occurred_at: 1.hour.ago) }
        .not_to change(BackgroundProcess, :count)
      expect(chip.name).to eq(JobNote::BALL_IN_COURT["take_home"])
    end
  end

  describe "it stops standing" do
    before { job.notes.create!(tag: :availability, occurred_at: 2.hours.ago) }

    it "takes the chip off the strip when the company takes the next move" do
      job.notes.create!(tag: :scheduled, occurred_at: 1.hour.ago, follow_up_at: 3.days.from_now)

      expect(chip).to be_nil
    end

    it "clears when the application is settled" do
      job.notes.create!(tag: :rejected, occurred_at: 1.hour.ago)

      expect(chip).to be_nil
    end

    # A retag is the ordinary repair, and the beat it was is the beat it is.
    it "clears when the beat is retagged to one of theirs" do
      job.notes.last.update!(tag: :heard_back)
      expect(chip).to be_present

      job.notes.last.update!(tag: :acknowledged)
      expect(chip).to be_nil
    end

    it "clears when the beat is deleted" do
      job.notes.last.destroy!

      expect(chip).to be_nil
    end
  end

  # The note's own `after_commit` runs on a destroy too, and the row can be gone
  # by the time it does.
  it "says nothing for an application that no longer exists" do
    expect(described_class.sync!(0)).to be_nil
    expect { job.destroy! }.not_to raise_error
  end
end
