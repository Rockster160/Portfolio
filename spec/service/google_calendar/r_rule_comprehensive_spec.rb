require "rails_helper"

# Comprehensive coverage of GoogleCalendar::RRule across the RFC 5545
# rule parts we actually round-trip with Google. Where we deliberately
# don't model a part (BYHOUR/BYWEEKNO/etc., WKST), that's documented as
# an explicit spec so the next person knows the gap is intentional.
#
# Organized by direction:
#   1. `.translate` — Google RRULE strings → our recurrence hash
#   2. `.serialize` — AgendaSchedule → Google RRULE lines
#   3. round-trip — pick representative shapes and make sure both
#      directions stay self-consistent
#   4. malformed / edge / "we explicitly don't support this"
#
# To add a regression spec when a discrepancy surfaces: drop it into the
# matching describe block.
RSpec.describe GoogleCalendar::RRule do
  # ---------------------------------------------------------------
  # Test double mirroring just the parts of AgendaSchedule that
  # .serialize actually reads — keeps these specs decoupled from the
  # model's validations, callbacks, and DB.
  ScheduleStruct = Struct.new(:recurrence, :until_on, :occurrence_count, keyword_init: true) unless defined?(ScheduleStruct)
  def sched(recurrence:, until_on: nil, occurrence_count: nil)
    ScheduleStruct.new(recurrence: recurrence, until_on: until_on, occurrence_count: occurrence_count)
  end

  # =================================================================
  # .translate — RFC 5545 rule parts → our recurrence shape
  # =================================================================

  describe ".translate FREQ" do
    it "DAILY with no INTERVAL → :daily" do
      result = described_class.translate(["RRULE:FREQ=DAILY"])
      expect(result[:recurrence]).to eq({ freq: :daily })
      expect(result[:skip]).to be(false)
    end

    it "DAILY with INTERVAL=1 → :daily (interval is implicit default)" do
      result = described_class.translate(["RRULE:FREQ=DAILY;INTERVAL=1"])
      expect(result[:recurrence]).to eq({ freq: :daily })
    end

    it "DAILY with INTERVAL>1 → :custom with unit:day" do
      result = described_class.translate(["RRULE:FREQ=DAILY;INTERVAL=3"])
      expect(result[:recurrence]).to eq({ freq: :custom, unit: :day, interval: 3 })
    end

    it "DAILY with INTERVAL=0 (technically invalid) coerces to 1 → :daily" do
      result = described_class.translate(["RRULE:FREQ=DAILY;INTERVAL=0"])
      expect(result[:recurrence]).to eq({ freq: :daily })
    end

    it "WEEKLY with no BYDAY → :weekly with empty by_day (caller falls back to starts_on.wday)" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY"])
      expect(result[:recurrence]).to eq({ freq: :weekly, by_day: [] })
    end

    it "WEEKLY with BYDAY=MO,WE,FR → :weekly with the listed days" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"])
      expect(result[:recurrence][:freq]).to eq(:weekly)
      expect(result[:recurrence][:by_day]).to match_array(%w[mon wed fri])
    end

    it "WEEKLY with BYDAY=MO,TU,WE,TH,FR + INTERVAL=1 → collapses to :weekdays" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
      expect(result[:recurrence]).to eq({ freq: :weekdays })
    end

    it "WEEKLY weekdays-MF with INTERVAL=2 stays :custom (not the :weekdays shortcut)" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU,WE,TH,FR"])
      expect(result[:recurrence]).to include(freq: :custom, unit: :week, interval: 2)
      expect(result[:recurrence][:by_day]).to match_array(%w[mon tue wed thu fri])
    end

    it "MONTHLY with BYMONTHDAY=15 → :monthly with by_month_day" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYMONTHDAY=15"])
      expect(result[:recurrence]).to eq({ freq: :monthly, by_month_day: [15] })
    end

    it "MONTHLY with BYMONTHDAY=-1 (last day of month) preserves -1" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYMONTHDAY=-1"])
      expect(result[:recurrence][:by_month_day]).to eq([-1])
    end

    it "MONTHLY with BYDAY=2MO + BYSETPOS=2 → :monthly with by_set_pos + by_day (second Monday)" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=2"])
      expect(result[:recurrence]).to eq({ freq: :monthly, by_set_pos: 2, by_day: ["mon"] })
    end

    it "MONTHLY with BYDAY=-1FR + BYSETPOS=-1 → last Friday of the month" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1"])
      expect(result[:recurrence]).to eq({ freq: :monthly, by_set_pos: -1, by_day: ["fri"] })
    end

    it "MONTHLY with no BYMONTHDAY or BYSETPOS → :monthly (caller uses starts_on.day)" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY"])
      expect(result[:recurrence]).to eq({ freq: :monthly })
    end

    it "YEARLY simple → :yearly" do
      result = described_class.translate(["RRULE:FREQ=YEARLY"])
      expect(result[:recurrence]).to eq({ freq: :yearly })
    end

    it "HOURLY (sub-day) → skip: true, no schedule should be created" do
      result = described_class.translate(["RRULE:FREQ=HOURLY;INTERVAL=2"])
      expect(result[:skip]).to be(true)
    end

    it "MINUTELY → skip: true" do
      result = described_class.translate(["RRULE:FREQ=MINUTELY"])
      expect(result[:skip]).to be(true)
    end

    it "SECONDLY → skip: true" do
      result = described_class.translate(["RRULE:FREQ=SECONDLY"])
      expect(result[:skip]).to be(true)
    end

    it "unknown FREQ falls through to :custom (defensive)" do
      result = described_class.translate(["RRULE:FREQ=BIANNUAL"])
      expect(result[:recurrence][:freq]).to eq(:custom)
    end
  end

  describe ".translate end conditions" do
    it "UNTIL with YYYYMMDD form parses to a Date" do
      result = described_class.translate(["RRULE:FREQ=DAILY;UNTIL=20260604"])
      expect(result[:until_on]).to eq(Date.new(2026, 6, 4))
      expect(result[:occurrence_count]).to be_nil
    end

    it "UNTIL with YYYYMMDDTHHMMSSZ (UTC datetime form) drops the time, keeps the date" do
      result = described_class.translate(["RRULE:FREQ=DAILY;UNTIL=20260604T235959Z"])
      expect(result[:until_on]).to eq(Date.new(2026, 6, 4))
    end

    it "COUNT alone parses to an integer; until_on stays nil (no premature derivation)" do
      result = described_class.translate(["RRULE:FREQ=DAILY;COUNT=7"])
      expect(result[:occurrence_count]).to eq(7)
      expect(result[:until_on]).to be_nil
    end

    it "neither UNTIL nor COUNT → both nil (open-ended)" do
      result = described_class.translate(["RRULE:FREQ=DAILY"])
      expect(result[:until_on]).to be_nil
      expect(result[:occurrence_count]).to be_nil
    end
  end

  describe ".translate EXDATE / RDATE" do
    it "EXDATE with comma-separated YYYYMMDDs lands in recurrence[:excluded_dates]" do
      result = described_class.translate([
        "RRULE:FREQ=DAILY",
        "EXDATE:20260603,20260610",
      ])
      expect(result[:recurrence][:excluded_dates]).to eq(["2026-06-03", "2026-06-10"])
    end

    it "EXDATE with TZID prefix (TZID=America/Denver:...) still extracts the date" do
      result = described_class.translate([
        "RRULE:FREQ=DAILY",
        "EXDATE;TZID=America/Denver:20260603T090000",
      ])
      expect(result[:recurrence][:excluded_dates]).to eq(["2026-06-03"])
    end

    it "RDATE inclusions land in recurrence[:included_dates]" do
      result = described_class.translate([
        "RRULE:FREQ=DAILY",
        "RDATE:20260615,20260622",
      ])
      expect(result[:recurrence][:included_dates]).to eq(["2026-06-15", "2026-06-22"])
    end

    it "no EXDATE/RDATE → neither key appears in the recurrence" do
      result = described_class.translate(["RRULE:FREQ=DAILY"])
      expect(result[:recurrence]).not_to have_key(:excluded_dates)
      expect(result[:recurrence]).not_to have_key(:included_dates)
    end
  end

  describe ".translate partial-fidelity flagging" do
    it "multiple RRULEs → first wins, partial: true" do
      result = described_class.translate([
        "RRULE:FREQ=WEEKLY;BYDAY=MO",
        "RRULE:FREQ=WEEKLY;BYDAY=FR",
      ])
      expect(result[:partial]).to be(true)
      expect(result[:recurrence][:by_day]).to eq(["mon"])
    end

    it "YEARLY with multi-BYMONTH (Mar, Jun, Sep) → partial: true (we don't model multi-month)" do
      result = described_class.translate(["RRULE:FREQ=YEARLY;BYMONTH=3,6,9;BYMONTHDAY=1"])
      expect(result[:partial]).to be(true)
    end

    it "single BYMONTH is NOT flagged partial (degenerate to plain YEARLY)" do
      result = described_class.translate(["RRULE:FREQ=YEARLY;BYMONTH=3"])
      expect(result[:partial]).to be(false)
    end

    %w[BYYEARDAY BYWEEKNO BYHOUR BYMINUTE BYSECOND].each do |part|
      it "#{part} refinement → partial: true (we don't model sub-day or week-of-year fidelity)" do
        result = described_class.translate(["RRULE:FREQ=YEARLY;#{part}=1"])
        expect(result[:partial]).to be(true)
      end
    end
  end

  describe ".translate input edge cases" do
    it "empty input → nil (no RRULE lines)" do
      expect(described_class.translate([])).to be_nil
    end

    it "non-RRULE lines only → nil" do
      expect(described_class.translate(["EXDATE:20260101"])).to be_nil
    end

    it "garbage RRULE without FREQ falls through to :custom with default day unit" do
      result = described_class.translate(["RRULE:INTERVAL=2"])
      expect(result[:recurrence]).to eq({ freq: :custom, unit: :day, interval: 2 })
    end

    it "WEEKLY with BYDAY=2MO (positional weekly variant) is treated as the plain weekday (we don't model positional inside WEEKLY)" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=2MO"])
      expect(result[:recurrence][:by_day]).to eq(["mon"])
    end

    it "DOES NOT model WKST (week-start) — silently dropped" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO;WKST=SU"])
      expect(result[:recurrence][:freq]).to eq(:weekly)
      # No WKST representation in the output hash — that's intentional.
      expect(result[:recurrence]).not_to have_key(:week_start)
    end
  end

  # =================================================================
  # .serialize — AgendaSchedule → RFC 5545 RRULE lines
  # =================================================================

  describe ".serialize FREQ" do
    it "daily → FREQ=DAILY" do
      lines = described_class.serialize(sched(recurrence: { freq: "daily" }))
      expect(lines).to eq(["RRULE:FREQ=DAILY"])
    end

    it "weekdays → FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR" do
      lines = described_class.serialize(sched(recurrence: { freq: "weekdays" }))
      expect(lines).to eq(["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
    end

    it "weekly with by_day → FREQ=WEEKLY;BYDAY=<days>" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "weekly", by_day: %w[mon wed fri] }),
      )
      expect(lines.first).to start_with("RRULE:FREQ=WEEKLY;BYDAY=")
      # by_day ordering preserves the input array, just maps to uppercase RFC codes.
      expect(lines.first).to include("MO", "WE", "FR")
    end

    it "weekly with NO by_day → FREQ=WEEKLY (no BYDAY clause)" do
      lines = described_class.serialize(sched(recurrence: { freq: "weekly", by_day: [] }))
      expect(lines).to eq(["RRULE:FREQ=WEEKLY"])
    end

    it "monthly with by_month_day → FREQ=MONTHLY;BYMONTHDAY=15" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "monthly", by_month_day: [15] }),
      )
      expect(lines).to eq(["RRULE:FREQ=MONTHLY;BYMONTHDAY=15"])
    end

    it "monthly with by_month_day=-1 (last day) preserves -1" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "monthly", by_month_day: [-1] }),
      )
      expect(lines).to eq(["RRULE:FREQ=MONTHLY;BYMONTHDAY=-1"])
    end

    it "monthly with by_set_pos + by_day → FREQ=MONTHLY;BYSETPOS;BYDAY (e.g. 2nd Monday)" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "monthly", by_set_pos: 2, by_day: ["mon"] }),
      )
      expect(lines).to eq(["RRULE:FREQ=MONTHLY;BYSETPOS=2;BYDAY=MO"])
    end

    it "monthly with by_set_pos=-1 + by_day → last weekday of month" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "monthly", by_set_pos: -1, by_day: ["fri"] }),
      )
      expect(lines).to eq(["RRULE:FREQ=MONTHLY;BYSETPOS=-1;BYDAY=FR"])
    end

    it "monthly with NEITHER by_month_day NOR by_set_pos → FREQ=MONTHLY (caller uses starts_on.day)" do
      lines = described_class.serialize(sched(recurrence: { freq: "monthly" }))
      expect(lines).to eq(["RRULE:FREQ=MONTHLY"])
    end

    it "yearly → FREQ=YEARLY" do
      lines = described_class.serialize(sched(recurrence: { freq: "yearly" }))
      expect(lines).to eq(["RRULE:FREQ=YEARLY"])
    end

    it "custom with unit=day + interval → FREQ=DAILY;INTERVAL=N" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "custom", unit: "day", interval: 3 }),
      )
      expect(lines).to eq(["RRULE:FREQ=DAILY;INTERVAL=3"])
    end

    it "custom with unit=week + interval → FREQ=WEEKLY;INTERVAL=N" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "custom", unit: "week", interval: 2 }),
      )
      expect(lines).to eq(["RRULE:FREQ=WEEKLY;INTERVAL=2"])
    end

    it "custom with unit=month + interval → FREQ=MONTHLY;INTERVAL=N" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "custom", unit: "month", interval: 6 }),
      )
      expect(lines).to eq(["RRULE:FREQ=MONTHLY;INTERVAL=6"])
    end

    it "custom with interval=1 omits the INTERVAL part" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "custom", unit: "day", interval: 1 }),
      )
      expect(lines).to eq(["RRULE:FREQ=DAILY"])
    end

    it "blank/missing freq → no rule (returns [])" do
      expect(described_class.serialize(sched(recurrence: {}))).to eq([])
      expect(described_class.serialize(sched(recurrence: nil))).to eq([])
    end
  end

  describe ".serialize end-condition priority (RFC 5545 mutual exclusion of UNTIL/COUNT)" do
    # REGRESSION GUARD — see r_rule_spec.rb for the original bug:
    # AgendaSchedule#sync_until_on_from_occurrence_count populates
    # until_on as a cache; serializer must NOT leak it to Google as
    # UNTIL when the user's intent was COUNT.

    it "COUNT alone → COUNT" do
      lines = described_class.serialize(sched(recurrence: { freq: "daily" }, occurrence_count: 7))
      expect(lines).to eq(["RRULE:FREQ=DAILY;COUNT=7"])
    end

    it "UNTIL alone → UNTIL" do
      lines = described_class.serialize(sched(recurrence: { freq: "daily" }, until_on: Date.new(2026, 6, 4)))
      expect(lines).to eq(["RRULE:FREQ=DAILY;UNTIL=20260604"])
    end

    it "both populated → COUNT wins (user intent over derived cache)" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "daily" }, occurrence_count: 7, until_on: Date.new(2026, 6, 4)),
      )
      expect(lines).to eq(["RRULE:FREQ=DAILY;COUNT=7"])
    end

    it "explicit until_on: arg overrides COUNT (destroy_series! truncation use case)" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "daily" }, occurrence_count: 7, until_on: Date.new(2026, 6, 4)),
        until_on: Date.new(2026, 5, 31),
      )
      expect(lines).to eq(["RRULE:FREQ=DAILY;UNTIL=20260531"])
    end

    it "neither populated → no end clause (open-ended)" do
      lines = described_class.serialize(sched(recurrence: { freq: "daily" }))
      expect(lines).to eq(["RRULE:FREQ=DAILY"])
    end

    it "occurrence_count=0 is treated as unset (not emitted as COUNT=0)" do
      lines = described_class.serialize(sched(recurrence: { freq: "daily" }, occurrence_count: 0))
      # `present?` is false for 0 only when it's blank — for Integer, 0.present? is true.
      # If you ever see `RRULE:...;COUNT=0` being sent: this spec will fail and tell you.
      expect(lines.first).not_to include("COUNT=0")
    end
  end

  describe ".serialize EXDATE emission" do
    it "excluded_dates → EXDATE: line with comma-separated YYYYMMDDs" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "daily", excluded_dates: ["2026-06-03", "2026-06-10"] }),
      )
      expect(lines).to eq([
        "RRULE:FREQ=DAILY",
        "EXDATE:20260603,20260610",
      ])
    end

    it "empty excluded_dates → no EXDATE line" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "daily", excluded_dates: [] }),
      )
      expect(lines).to eq(["RRULE:FREQ=DAILY"])
    end

    it "ungarbleable date strings get filter_mapped out, valid ones survive" do
      lines = described_class.serialize(
        sched(recurrence: { freq: "daily", excluded_dates: ["2026-06-03", "not-a-date", "2026-06-10"] }),
      )
      expect(lines).to eq([
        "RRULE:FREQ=DAILY",
        "EXDATE:20260603,20260610",
      ])
    end
  end

  # =================================================================
  # round-trip: Google → us → Google for representative cases
  # =================================================================

  describe "round-trip integrity" do
    it "FREQ=DAILY survives translate → serialize" do
      parsed = described_class.translate(["RRULE:FREQ=DAILY"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=DAILY"])
    end

    it "FREQ=WEEKLY;BYDAY=MO,WE,FR survives translate → serialize" do
      parsed = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out.first).to start_with("RRULE:FREQ=WEEKLY;BYDAY=")
      %w[MO WE FR].each { |code| expect(out.first).to include(code) }
    end

    it "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR (weekdays) survives losslessly" do
      parsed = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
    end

    it "FREQ=MONTHLY;BYMONTHDAY=15 survives losslessly" do
      parsed = described_class.translate(["RRULE:FREQ=MONTHLY;BYMONTHDAY=15"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=MONTHLY;BYMONTHDAY=15"])
    end

    it "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=2 (second Monday) survives losslessly" do
      parsed = described_class.translate(["RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=2"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=MONTHLY;BYSETPOS=2;BYDAY=MO"])
    end

    it "FREQ=DAILY;INTERVAL=3 survives losslessly" do
      parsed = described_class.translate(["RRULE:FREQ=DAILY;INTERVAL=3"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=DAILY;INTERVAL=3"])
    end

    it "FREQ=DAILY;COUNT=7 survives losslessly (COUNT preserved on the way back out)" do
      parsed = described_class.translate(["RRULE:FREQ=DAILY;COUNT=7"])
      out = described_class.serialize(
        sched(recurrence: parsed[:recurrence], occurrence_count: parsed[:occurrence_count]),
      )
      expect(out).to eq(["RRULE:FREQ=DAILY;COUNT=7"])
    end

    it "FREQ=DAILY;UNTIL=20260604 survives losslessly" do
      parsed = described_class.translate(["RRULE:FREQ=DAILY;UNTIL=20260604"])
      out = described_class.serialize(
        sched(recurrence: parsed[:recurrence], until_on: parsed[:until_on]),
      )
      expect(out).to eq(["RRULE:FREQ=DAILY;UNTIL=20260604"])
    end

    it "EXDATE inclusion survives both directions" do
      parsed = described_class.translate([
        "RRULE:FREQ=DAILY",
        "EXDATE:20260603,20260610",
      ])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq([
        "RRULE:FREQ=DAILY",
        "EXDATE:20260603,20260610",
      ])
    end

    it "FREQ=YEARLY survives losslessly" do
      parsed = described_class.translate(["RRULE:FREQ=YEARLY"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=YEARLY"])
    end

    # ----- known-lossy round trips: document the loss explicitly -----

    it "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO survives FREQ+INTERVAL but DROPS by_day on the way back out (custom serializer doesn't emit BYDAY)" do
      parsed = described_class.translate(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=WEEKLY;INTERVAL=2"])
      # If you ever fix custom-with-by_day serialization, update this spec
      # to expect the full BYDAY=MO clause and remove this comment.
    end

    it "WKST does NOT round-trip (we don't model it on either side)" do
      parsed = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO;WKST=SU"])
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=WEEKLY;BYDAY=MO"])
    end

    it "BYYEARDAY/BYWEEKNO/etc are dropped on translate (partial=true) and don't appear on serialize" do
      parsed = described_class.translate(["RRULE:FREQ=YEARLY;BYWEEKNO=20"])
      expect(parsed[:partial]).to be(true)
      out = described_class.serialize(sched(recurrence: parsed[:recurrence]))
      expect(out).to eq(["RRULE:FREQ=YEARLY"])
    end
  end

  # =================================================================
  # Future regression hooks — add here as bugs surface.
  # =================================================================

  describe "regression-guard slots" do
    it "REGRESSION (UNTIL leaked when intent was COUNT): COUNT-derived until_on cache doesn't escape to Google" do
      # The original bug: until_on populated by before_save callback
      # ended up serialized as UNTIL=... back to Google, silently
      # converting "Repeat 7 times" into "Repeat until ...".
      lines = described_class.serialize(
        sched(
          recurrence: { freq: "daily" },
          occurrence_count: 7,
          until_on: Date.new(2026, 6, 4), # derived cache
        ),
      )
      expect(lines.first).to include("COUNT=7")
      expect(lines.first).not_to include("UNTIL=")
    end

    # Add `it "REGRESSION (...)"` blocks below as new asymmetries surface.
    # Pattern: copy the failing input, fix the code, drop the spec in.
  end
end
