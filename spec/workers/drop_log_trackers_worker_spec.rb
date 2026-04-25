RSpec.describe DropLogTrackersWorker, type: :worker do
  it "deletes rows older than the retention window" do
    old = LogTracker.create!(created_at: 6.weeks.ago, updated_at: 6.weeks.ago)
    edge = LogTracker.create!(created_at: (described_class::RETENTION.ago - 1.day), updated_at: 1.day.ago)
    fresh = LogTracker.create!(created_at: 1.day.ago, updated_at: 1.day.ago)

    described_class.new.perform

    expect(LogTracker.exists?(old.id)).to be(false)
    expect(LogTracker.exists?(edge.id)).to be(false)
    expect(LogTracker.exists?(fresh.id)).to be(true)
  end

  it "deletes in batches rather than a single statement" do
    total = (described_class::BATCH_SIZE * 2) + 5
    rows = Array.new(total) { |i|
      { created_at: 6.weeks.ago - i.seconds, updated_at: 6.weeks.ago - i.seconds }
    }
    LogTracker.insert_all(rows) # rubocop:disable Rails/SkipsModelValidations

    expect(LogTracker.connection).to receive(:exec_delete).at_least(:twice).and_call_original

    expect { described_class.new.perform }.to change(LogTracker, :count).by(-total)
  end
end
