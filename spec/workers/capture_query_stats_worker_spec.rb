RSpec.describe CaptureQueryStatsWorker, type: :worker do
  let(:database) { PgHero.primary_database.id }

  before do
    allow(PgHero).to receive(:capture_query_stats)
    travel_to(Time.utc(2026, 11, 20, 12))
  end

  def capture(at, hash: 1, calls: 1, total_time: 10.0)
    PgHero::QueryStats.create!(
      database:    database,
      user:        "portfolio",
      query:       "SELECT #{hash}",
      query_hash:  hash,
      total_time:  total_time,
      calls:       calls,
      captured_at: at,
    )
  end

  def rows
    PgHero::QueryStats.order(:captured_at, :query_hash).pluck(:query_hash, :captured_at, :calls)
  end

  it "keeps every capture inside the full-detail window" do
    capture(Time.utc(2026, 11, 1, 10, 0, 5))
    capture(Time.utc(2026, 11, 1, 10, 5, 5))
    capture(Time.utc(2026, 8, 22, 0, 0, 5))

    expect { described_class.new.perform }.not_to(change { rows })
  end

  it "folds captures past 90 days into one row per query per day" do
    capture(Time.utc(2026, 8, 1, 10, 0, 5), calls: 3, total_time: 30.0)
    capture(Time.utc(2026, 8, 1, 10, 5, 5), calls: 4, total_time: 40.0)
    capture(Time.utc(2026, 8, 1, 11, 0, 5), hash: 2, calls: 9)
    capture(Time.utc(2026, 8, 2, 9, 0, 5), calls: 1)

    described_class.new.perform

    expect(rows).to eq([
      [1, Time.utc(2026, 8, 1), 7],
      [2, Time.utc(2026, 8, 1), 9],
      [1, Time.utc(2026, 8, 2), 1],
    ])
    expect(PgHero::QueryStats.find_by(captured_at: Time.utc(2026, 8, 1), query_hash: 1).total_time).to eq(70.0)
  end

  it "folds anything past a year, daily summaries included, into one row per query per week" do
    capture(Time.utc(2025, 6, 2), calls: 1)
    capture(Time.utc(2025, 6, 3), calls: 5)
    capture(Time.utc(2025, 6, 5, 13, 0, 5), calls: 2)

    described_class.new.perform

    expect(rows).to eq([[1, Time.utc(2025, 6, 2), 8]])
  end

  it "keeps the totals of everything it rolls" do
    capture(Time.utc(2026, 8, 1, 10, 0, 5), calls: 3, total_time: 30.5)
    capture(Time.utc(2025, 6, 3, 10, 0, 5), calls: 4, total_time: 12.25)
    capture(Time.utc(2025, 6, 4), calls: 6, total_time: 1.0)

    expect { described_class.new.perform }.not_to(change {
      PgHero::QueryStats.pluck(Arel.sql("SUM(calls)"), Arel.sql("SUM(total_time)"))
    })
  end

  it "writes nothing when every old bucket is already summarized" do
    capture(Time.utc(2026, 8, 1, 10, 0, 5))
    capture(Time.utc(2025, 6, 3, 10, 0, 5))
    described_class.new.perform

    expect { described_class.new.perform }.not_to(change { PgHero::QueryStats.order(:id).pluck(:id) })
  end
end
