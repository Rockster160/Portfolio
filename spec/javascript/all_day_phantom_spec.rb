require "rails_helper"
require "json"
require "open3"

# Regression guard for the "Tela's Birthday spans yesterday and today
# both" bug. The cal_week / cal_month banner layouts read
# `presentation_attrs["end-date"]` and translate the epoch into a column
# via `formatDateISO`. For an all-day phantom the previous implementation
# emitted the EXCLUSIVE next-day midnight (start_at + duration_min*60),
# so every Google-synced recurring all-day event bled into the next day's
# column. The convention enforced here matches both
# `optimistic_item.js` (`endAt - 86400` for all-day) and
# `AgendaItem#presentation_attrs` (`end_date.in_time_zone(user.tz)
# .beginning_of_day.to_i`).
RSpec.describe "AgendaRecurrence all-day phantom end-date (JS-side)" do
  let(:runner_path) {
    Rails.root.join("spec", "javascript", "all_day_phantom_runner.js").to_s
  }
  let(:cases) {
    stdout, stderr, status = Open3.capture3("node", runner_path)
    raise "runner failed: #{stderr}" unless status.success?
    JSON.parse(stdout, symbolize_names: true)[:cases]
  }
  let(:by_name) { cases.to_h { |c| [c[:name].to_sym, c] } }

  it "emits end-date == start-at for a single-day all-day phantom" do
    c = by_name[:single_day_all_day]
    expect(c[:end_date_epoch]).to eq(c[:start_at]),
      "single-day all-day chip should NOT span into the next column"
  end

  it "emits end-date == start-at + 2 days for a three-day all-day phantom" do
    c = by_name[:three_day_all_day]
    expect(c[:end_date_epoch]).to eq(c[:start_at] + (2 * 86_400)),
      "three-day all-day chip should anchor on day-1, day-2, day-3 inclusive"
  end

  it "leaves timed events alone (no all-day walk-back applied)" do
    c = by_name[:timed_event_unchanged]
    expect(c[:end_date_epoch]).to eq(c[:end_at]),
      "timed events keep end-date == end-at — only all-day gets the walk-back"
  end
end
