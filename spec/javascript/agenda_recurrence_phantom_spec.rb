require "rails_helper"

RSpec.describe "AgendaRecurrence phantoms (JS-side)" do
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
  describe "all-day phantom end-date" do
    let(:cases) { JsRunner.output("spec/javascript/all_day_phantom_runner.js", symbolize: true)[:cases] }
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

  # Regression guard for "future TMS occurrences don't show the travel
  # band." Future occurrences come from the JS phantom expander which used
  # to hardcode `"travel-minutes": 0`, so the band height computed to zero.
  # This spec locks the nested-`metadata.travel.*` inheritance contract on
  # the JS side so a future refactor of `recurrence.js#buildPhantom` can't
  # silently break it again. (The legacy top-level `metadata.travel_minutes`
  # shape is no longer supported — the resolver migrated it into `travel`.)
  describe "travel inheritance" do
    let(:by_name) {
      JsRunner.output("spec/javascript/phantom_travel_inheritance_runner.js", symbolize: true)[:cases]
        .to_h { |c| [c[:name].to_sym, c[:attrs]] }
    }

    it "inherits every nested metadata.travel.* field" do
      a = by_name[:full_travel_chain]
      expect(a[:"travel-minutes"]).to       eq(15)
      expect(a[:"resolved-address"]).to     eq("13123 S 5600 W, Herriman, UT 84096")
      expect(a[:"travel-from"]).to          eq("Home St")
      expect(a[:"travel-from-kind"]).to     eq("home")
      expect(a[:"chain-predecessor-id"]).to eq(99)
      expect(a[:"chain-successor-id"]).to   eq(100)
      expect(a[:"chain-prev-end-epoch"]).to eq(1234)
      expect(a[:"leave-at-epoch"]).to       eq(5678)
      expect(a[:"arrive-early-minutes"]).to eq(5)
    end

    it "derives the return-home band on phantoms from the schedule's mirrored minutes" do
      a = by_name[:return_home_baseline]
      expect(a[:"post-travel-minutes"]).to eq(12)
      # post_arrive_at is per-occurrence (not mirrored), so the phantom derives
      # it from its own end (17:00 + 60m = 18:00 UTC) + 12*60.
      expect(a[:"post-arrive-at-epoch"]).to eq(Time.utc(2026, 6, 24, 18, 0, 0).to_i + 12 * 60)
    end

    it "defaults to zero / empty when the schedule has no metadata" do
      a = by_name[:no_metadata]
      expect(a[:"travel-minutes"]).to       eq(0)
      expect(a[:"resolved-address"]).to     eq("")
      expect(a[:"travel-from"]).to          eq("")
      expect(a[:"travel-from-kind"]).to     eq("")
      expect(a[:"chain-predecessor-id"]).to eq("")
      expect(a[:"chain-successor-id"]).to   eq("")
      expect(a[:"chain-prev-end-epoch"]).to eq("")
      expect(a[:"leave-at-epoch"]).to       eq("")
    end
  end
end
