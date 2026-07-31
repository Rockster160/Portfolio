RSpec.describe Execution, type: :model do
  let(:user) { FactoryBot.create(:user, phone: "5559990301") }
  let(:other_user) { FactoryBot.create(:user, phone: "5559990302") }
  let(:task) {
    Task.create!(user: user, name: "Usage Subject", listener: "tell:use", code: "// noop", enabled: true)
  }

  def make_execution(started_at:, owner: user)
    Execution.create!(
      user: owner, task: task, status: :success, auth_type: :trigger,
      started_at: started_at, finished_at: started_at + 0.1.seconds
    )
  end

  # The archive carries the original execution's id and has no sequence of its
  # own, so a row can only be written with one supplied.
  def make_archived(started_at:, owner: user)
    make_execution(started_at: started_at, owner: owner)
    ExecutionArchiveWorker.new.perform(0)
  end

  describe ".usage_count" do
    it "counts across both the hot table and the archive" do
      make_execution(started_at: 2.days.ago)
      make_archived(started_at: 200.days.ago)

      expect(described_class.usage_count(since: 1.year.ago)).to eq(2)
    end

    it "does not under-report once rows have been archived" do
      3.times { |i| make_execution(started_at: (i + 1).days.ago) }
      before = described_class.usage_count(since: 1.year.ago)

      ExecutionArchiveWorker.new.perform(0)

      expect(described_class.count).to eq(0)
      expect(described_class.usage_count(since: 1.year.ago)).to eq(before)
    end

    it "honours the time window" do
      make_archived(started_at: 200.days.ago)
      make_execution(started_at: 2.days.ago)

      expect(described_class.usage_count(since: 30.days.ago)).to eq(1)
    end

    it "scopes to a user when given one" do
      make_execution(started_at: 1.day.ago)
      make_archived(started_at: 100.days.ago, owner: other_user)

      expect(described_class.usage_count(since: 1.year.ago, user: user)).to eq(1)
      expect(described_class.usage_count(since: 1.year.ago, user: other_user)).to eq(1)
      expect(described_class.usage_count(since: 1.year.ago)).to eq(2)
    end
  end

  describe ".usage_over_time" do
    it "buckets executions spanning both tables" do
      make_archived(started_at: 3.days.ago.midday)
      make_archived(started_at: 3.days.ago.midday + 1.hour)
      make_execution(started_at: 1.day.ago.midday)

      buckets = described_class.usage_over_time(since: 10.days.ago, bucket: :day)

      expect(buckets.map(&:last)).to eq([2, 1])
      expect(buckets.length).to eq(2)
    end

    it "keeps timestamps intact through archiving so the series is unchanged" do
      make_execution(started_at: 3.days.ago.midday)
      make_execution(started_at: 1.day.ago.midday)
      before = described_class.usage_over_time(since: 10.days.ago)

      ExecutionArchiveWorker.new.perform(0)

      expect(described_class.usage_over_time(since: 10.days.ago)).to eq(before)
    end

    it "falls back to day for an unrecognised bucket" do
      make_execution(started_at: 1.day.ago.midday)

      expect(described_class.usage_over_time(since: 10.days.ago, bucket: :nonsense).length).to eq(1)
    end
  end
end
