require "rails_helper"

RSpec.describe ChartBuilder do
  let(:user) { create(:user) }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }

  def event(name, at:, notes: nil, data: {})
    user.action_events.create!(name: name, timestamp: at, notes: notes, data: data)
  end

  def chart(query:, **config)
    CustomChart.create!(user: user, name: "Test", query: query, config: config)
  end

  describe "notes sum, month buckets (Pullups)" do
    it "sums notes-as-int into month buckets across a dense range" do
      event("Pullups", at: tz.local(2026, 1, 10, 12), notes: "5")
      event("Pullups", at: tz.local(2026, 1, 20, 12), notes: "10")
      event("Pullups", at: tz.local(2026, 2, 5, 12), notes: "5")
      event("Other",   at: tz.local(2026, 1, 15, 12), notes: "99") # filtered out

      result = described_class.new(
        chart(query: "name::Pullups", value_source: :notes, metric: :sum, bucket: :month, chart_type: :bar),
        start_at: "2026-01-01", end_at: "2026-02-28",
      ).call

      expect(result[:labels]).to eq(["Jan 2026", "Feb 2026"])
      expect(result[:datasets].length).to eq(1)
      expect(result[:datasets].first[:data]).to eq([15, 5])
      expect(result[:stats][:total]).to eq(20)
      expect(result[:stats][:count]).to eq(3)
    end
  end

  describe "data_keys series, point mode (Feelings)" do
    it "emits one dataset per data key with a point per event" do
      event("Feeling", at: tz.local(2026, 1, 10, 12), data: { "Happy" => "80", "Calm" => "40" })
      event("Feeling", at: tz.local(2026, 1, 12, 12), data: { "Happy" => "60", "Calm" => "50" })

      result = described_class.new(
        chart(query: "name::Feeling", series_by: :data_keys, metric: :avg, bucket: :none, chart_type: :line),
        start_at: "2026-01-01", end_at: "2026-01-31",
      ).call

      expect(result[:time_axis]).to be(true)
      labels = result[:datasets].pluck(:label)
      expect(labels).to contain_exactly("Happy", "Calm")

      happy = result[:datasets].find { |ds| ds[:label] == "Happy" }
      expect(happy[:data].pluck(:y)).to eq([80.0, 60.0])
    end
  end

  describe "sign split, month buckets (Transactions)" do
    it "splits positive vs negative amounts into two datasets" do
      event("Transaction", at: tz.local(2026, 1, 5, 12),  data: { "amount" => 100.0 })
      event("Transaction", at: tz.local(2026, 1, 8, 12),  data: { "amount" => 50.0 })
      event("Transaction", at: tz.local(2026, 1, 20, 12), data: { "amount" => -30.0 })

      result = described_class.new(
        chart(
          query: "name::Transaction", value_source: :data, data_key: "amount",
          series_by: :sign, metric: :sum, bucket: :month, chart_type: :bar, unit: "$"
        ),
        start_at: "2026-01-01", end_at: "2026-01-31",
      ).call

      positive = result[:datasets].find { |ds| ds[:label] == "Positive" }
      negative = result[:datasets].find { |ds| ds[:label] == "Negative" }
      expect(positive[:data]).to eq([150.0])
      # Magnitude, not the signed sum — so it compares against the positive arm.
      expect(negative[:data]).to eq([30.0])
      expect(positive[:color]).to eq(described_class::POSITIVE_COLOR)
    end
  end

  describe "gap metric, point mode (nail cadence)" do
    it "plots days between consecutive matching events" do
      event("Shower", at: tz.local(2026, 1, 1, 12),  data: { "actions" => ["Cut Finger Nails"] })
      event("Shower", at: tz.local(2026, 1, 15, 12), data: { "actions" => ["Cut Finger Nails"] })
      event("Shower", at: tz.local(2026, 1, 29, 12), data: { "actions" => ["Washed Body"] }) # no match

      result = described_class.new(
        chart(query: 'name::Shower action:"Cut Finger Nails"', metric: :gap, bucket: :none, chart_type: :line),
        start_at: "2026-01-01", end_at: "2026-02-28",
      ).call

      ys = result[:datasets].first[:data].pluck(:y)
      expect(ys).to eq([14.0])
    end
  end

  describe "notes series (one series per distinct note)" do
    it "splits matching events into a series per notes value" do
      event("Z", at: tz.local(2026, 1, 5, 12), notes: "cardio")
      event("Z", at: tz.local(2026, 1, 9, 12), notes: "cardio")
      event("Z", at: tz.local(2026, 1, 20, 12), notes: "strength")

      result = described_class.new(
        chart(query: "name::Z", series_by: :notes, metric: :count, bucket: :month, chart_type: :line),
        start_at: "2026-01-01", end_at: "2026-01-31",
      ).call

      labels = result[:datasets].pluck(:label)
      expect(labels).to contain_exactly("cardio", "strength")
      expect(result[:datasets].find { |d| d[:label] == "cardio" }[:data]).to eq([2])
      expect(result[:datasets].find { |d| d[:label] == "strength" }[:data]).to eq([1])
    end
  end

  describe "multiple queries as separate series" do
    it "builds one dataset per query line" do
      event("X", at: tz.local(2026, 1, 10, 12))
      event("X", at: tz.local(2026, 1, 20, 12))
      event("Z", at: tz.local(2026, 1, 15, 12))

      result = described_class.new(
        chart(query: "", metric: :count, bucket: :month, chart_type: :line, queries: "X = name::X\nZ = name::Z"),
        start_at: "2026-01-01", end_at: "2026-01-31",
      ).call

      labels = result[:datasets].pluck(:label)
      expect(labels).to eq(["X", "Z"])
      expect(result[:datasets].find { |d| d[:label] == "X" }[:data]).to eq([2])
      expect(result[:datasets].find { |d| d[:label] == "Z" }[:data]).to eq([1])
    end
  end

  describe "marker query" do
    it "returns marker events with name/notes/date and bucket epochs for overlay lines" do
      event("X", at: tz.local(2026, 1, 10, 12))
      event("K", at: tz.local(2026, 1, 18, 9), notes: "milestone")

      result = described_class.new(
        chart(query: "name::X", metric: :count, bucket: :month, chart_type: :bar, marker_query: "name::K"),
        start_at: "2026-01-01", end_at: "2026-01-31",
      ).call

      expect(result[:markers].length).to eq(1)
      marker = result[:markers].first
      expect(marker[:ts]).to eq(tz.local(2026, 1, 18, 9).to_i * 1000)
      expect(marker[:name]).to eq("K")
      expect(marker[:notes]).to eq("milestone")
      expect(marker[:date]).to be_present
      expect(result[:buckets_ms]).to eq([tz.local(2026, 1, 1).beginning_of_month.to_i * 1000])
    end
  end

  describe "custom colors" do
    it "overrides a series color by its label" do
      event("X", at: tz.local(2026, 1, 10, 12))
      event("Z", at: tz.local(2026, 1, 12, 12))

      result = described_class.new(
        chart(
          query: "", metric: :count, bucket: :month, chart_type: :line,
          queries: "X = name::X\nZ = name::Z", colors: "Z = #abcdef"
        ),
        start_at: "2026-01-01", end_at: "2026-01-31",
      ).call

      expect(result[:datasets].find { |d| d[:label] == "Z" }[:color]).to eq("#abcdef")
      # Unspecified series fall back to the palette.
      expect(result[:datasets].find { |d| d[:label] == "X" }[:color]).to eq(described_class::PALETTE.first)
    end
  end

  describe "guarding" do
    it "degrades gracefully on odd query syntax instead of raising" do
      builder = described_class.new(chart(query: "name:::::((", bucket: :month))
      result = nil
      expect { result = builder.call }.not_to raise_error
      expect(result[:datasets]).to be_an(Array)
    end

    it "rescues a StatementInvalid into an error payload" do
      builder = described_class.new(chart(query: "name::Pullups", bucket: :month))
      allow(builder).to receive(:series_defs).and_raise(ActiveRecord::StatementInvalid)
      result = builder.call
      expect(result[:datasets]).to eq([])
      expect(result[:error]).to be_present
    end
  end
end
