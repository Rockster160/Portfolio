require "rails_helper"

RSpec.describe "Agenda search modal (JS-side)" do
  # "Whisper's Birthday shows up in the calendar when I navigate to the
  # day, but not in the search." The store carries a recurring series as
  # a RULE plus the rows the server has materialized — 30 hours' worth —
  # and the search modal read only the rows. A yearly birthday has none
  # for 364 days of the year, so the box could never find it while the
  # day view beside it drew it perfectly.
  let(:result) {
    JsRunner.output("spec/javascript/agenda_search_modal_runner.js", symbolize: true)
  }

  it "finds a birthday that exists only as a recurrence rule" do
    expect(result[:hits].length).to eq(1)
    expect(result[:hits].first[:lines]).to include("Whisper's Birthday")
  end

  it "puts the next occurrence on the row, not the rule's anchor year" do
    expect(result[:hits].first[:lines].first).to eq("Wed, Oct 14, 2026 · all day")
  end

  it "carries the schedule summary and the rest of the series" do
    expect(result[:hits].first[:lines].last).to eq("Yearly · 1 upcoming, 1 past")
  end

  it "marks a hit on a read-only calendar as readonly" do
    # Birthdays is derived from contacts; the details modal must not
    # offer an Edit button that can't work.
    expect(result[:hits].first[:readonly]).to be(true)
  end

  it "shows the upcoming section once there is something in it" do
    expect(result[:future_section_shown]).to be(true)
  end

  it "leaves out the duplicate the filter panel is hiding" do
    # BirthdaySync finds a pre-existing "Whisper Birthday" on another
    # calendar and hides it so the two don't stack. The calendar's own
    # hide pass walks rendered .agenda-item / .cal-* nodes, which a
    # search hit is neither of — so search used to be the one view that
    # ignored every filter, and put the hidden copy right back under
    # the one it was hidden for.
    expect(result[:hits].length).to eq(1)
  end

  it "shows both again once the hide is lifted" do
    expect(result[:unhidden_names]).to eq(["Whisper Birthday", "Whisper's Birthday"])
  end

  it "still says nothing when nothing matches" do
    expect(result[:no_match_rows]).to eq(0)
    expect(result[:no_match_section_hidden]).to be(true)
  end
end
