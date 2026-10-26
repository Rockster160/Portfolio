require "rails_helper"

# The week's weather, laid out by code under a Today briefing so the companion
# never has to read a forecast out as a sentence.
RSpec.describe Buddy::ForecastTable do
  let(:today) { Date.new(2026, 10, 26) }

  def row(date, **attrs)
    { date: date, high: 65, low: 41, rain: 0, sky: "Clear", clouds: 0, notable: nil }.merge(attrs)
  end

  it "gives each day its sky, its high and low, and the odds on a wet one" do
    table = described_class.table(
      [row(today, sky: "Rain", rain: 60, notable: "rain"), row(today + 1, high: 58, low: 40)],
      today: today,
    )

    expect(table.lines.map(&:strip)).to eq([
      "| | Home |",
      "|---|---|",
      "| Today | 🌧️ 65°/41° · 60% |",
      "| Tue | ☀️ 58°/40° |",
    ])
  end

  it "adds an Alpine column only when Alpine has rain to show" do
    table = described_class.table([row(today, alpine: "1-3pm"), row(today + 2)], today: today)

    expect(table).to start_with("| | Home | Alpine |\n|---|---|---|")
    expect(table).to include("| Today | ☀️ 65°/41° | 1-3pm |", "| Wed | ☀️ 65°/41° |  |")
  end

  it "reads a date that came back through metadata as a string" do
    expect(described_class.table([row("2026-10-27")], today: today)).to include("| Tue |")
  end

  it "flags wind alongside the sky" do
    expect(described_class.table([row(today, notable: "windy")], today: today)).to include("☀️ 💨 65°/41°")
  end

  it "leaves odds too small to plan around off" do
    expect(described_class.table([row(today, notable: "rain", rain: 5)], today: today)).to include("| 🌧️ 65°/41° |")
  end

  it "is nothing when there are no days" do
    expect(described_class.table([], today: today)).to be_nil
  end

  it "comes back off the end of a body, leaving the words" do
    body = "Morning!\n\nBluestaq at 9:30.\n\n#{described_class.table([row(today)], today: today)}"

    expect(described_class.strip(body)).to eq("Morning!\n\nBluestaq at 9:30.")
  end

  it "leaves a body with no table alone" do
    expect(described_class.strip("Morning! | not a table |")).to eq("Morning! | not a table |")
  end
end
