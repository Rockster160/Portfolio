require "rails_helper"

RSpec.describe "AgendaStore.scheduleOccurrences (JS-side)" do
  # Regression guard for "the calendar shows Whisper's Birthday on its
  # day and the search box can't find it." The store holds a recurring
  # series as a RULE plus whatever rows the server has materialized —
  # 30 hours' worth — so a yearly birthday has no AgendaItem for 364
  # days of the year. The day view expands the rule; the search modal
  # filtered `state.items` and therefore looked straight past it.
  let(:cases) {
    JsRunner.output("spec/javascript/agenda_schedule_occurrences_runner.js", symbolize: true)
  }

  it "finds a yearly series that has no materialized row anywhere" do
    dates = cases[:birthday_forward].pluck(:occurrence_date)
    expect(dates).to eq(%w[2026-10-14 2027-10-14])
  end

  it "hands back occurrence-shaped rows the renderer can draw" do
    row = cases[:birthday_forward].first
    expect(row[:id]).to                 eq("p-149-2026-10-14")
    expect(row[:agenda_schedule_id]).to eq(149)
    expect(row[:all_day]).to            be(true)
    # The Birthdays calendar is read-only, and a search hit has to say so
    # or the details modal offers an Edit button that can't work.
    expect(row[:editable]).to be(false)
  end

  it "takes the MOST RECENT occurrence from a backwards window" do
    expect(cases[:birthday_back].pluck(:occurrence_date)).to eq(%w[2025-10-14])
  end

  it "skips the date a materialized row already covers" do
    dates = cases[:standup_forward].pluck(:occurrence_date)
    expect(dates).not_to include("2026-06-22"),
      "today's stand-up has a real row — a phantom beside it is the same morning twice"
    expect(dates.first).to eq("2026-06-29")
  end

  it "walks no rules for a predicate that matches nothing" do
    expect(cases[:no_match]).to be_empty
  end

  it "leaves the calendar's own range read alone" do
    # itemsForRange and scheduleOccurrences now share one suppression
    # map; the extraction must not change what the day view sees.
    expect(cases[:range_today].pluck(:id)).to eq(%w[5001])
  end
end
