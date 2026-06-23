require "rails_helper"
require "json"
require "open3"

# Locks the natural-language parser for the Agenda Quick Add modal at
# the same capability tier as `Jarvis::Times` + `Jarvis::Durations`.
# Every case sets an explicit `now` so the assertions don't drift with
# wall clock. Sections are organized as: (1) original three user
# examples, (2) always-future + PM-default intent calls, (3) every
# grammar feature (explicit AM/PM, noon/midnight, durations, relative
# offsets, weak day words, weekday hints, date forms), (4) "on the Nth"
# regression, (5) error cases, (6) duration-only probes.
RSpec.describe "AgendaQuickAddParser (JS-side)" do
  let(:runner_path) {
    Rails.root.join("spec", "javascript", "quick_add_parser_runner.js").to_s
  }
  let(:by_name) {
    stdout, stderr, status = Open3.capture3("node", runner_path)
    raise "runner failed: #{stderr}" unless status.success?
    JSON.parse(stdout, symbolize_names: true)[:cases].to_h { |c| [c[:name].to_sym, c[:result]] }
  }

  describe "the three example inputs" do
    it "no-time input snaps to the next half-hour, 60-min default" do
      r = by_name[:trash_no_time]
      expect(r).to include(ok: true, name: "take out the trash", durationMin: 60)
      # MON_10_23 (10:23am) → next half-hour = 10:30.
      expect(r[:startsAt]).to eq("2026-06-22 10:30")
      expect(r[:endsAt]).to   eq("2026-06-22 11:30")
    end

    it "`at 7` at 10:23am → 7pm same day (PM default + future)" do
      r = by_name[:trash_at_7_morning]
      expect(r[:startsAt]).to eq("2026-06-22 19:00")
    end

    it "`at 7` at 8pm → 7am tomorrow (nearest-future occurrence, 7 is outside 12am-5am skip)" do
      r = by_name[:trash_at_7_after_7pm]
      expect(r[:startsAt]).to eq("2026-06-23 07:00")
    end

    it "`Saturday at 4 for 3 hours` → next Saturday 4pm, 180-minute duration" do
      r = by_name[:lucky_ones_saturday]
      expect(r[:name]).to eq("Lucky Ones")
      expect(r[:durationMin]).to eq(180)
      expect(r[:startsAt]).to eq("2026-06-27 16:00")
      expect(r[:endsAt]).to   eq("2026-06-27 19:00")
    end
  end

  describe "PM-default + always-future intent" do
    it "`tomorrow at 4` at 6pm → 4pm tomorrow (user's stated example)" do
      expect(by_name[:tomorrow_at_4_pm_intent][:startsAt]).to eq("2026-06-23 16:00")
    end

    it "`at 4` in the morning still defaults to 4pm today" do
      expect(by_name[:at_4_morning_pm_default][:startsAt]).to eq("2026-06-23 16:00")
    end

    it "explicit `4am` overrides the PM heuristic" do
      expect(by_name[:at_4_am_explicit][:startsAt]).to eq("2026-06-24 04:00")
    end

    it "ambiguous `at 8` picks 8pm same day when 8am has passed (nearest future)" do
      # 10:23 → 8am has passed, 8pm is still future → 8pm today.
      expect(by_name[:future_roll_ambiguous_8][:startsAt]).to eq("2026-06-22 20:00")
    end

    it "explicit `at 9am` past-due rolls forward 24h" do
      expect(by_name[:future_roll_explicit_am][:startsAt]).to eq("2026-06-23 09:00")
    end
  end

  describe "noon / midnight / explicit am/pm" do
    it("noon")        { expect(by_name[:noon][:startsAt]).to        eq("2026-06-22 12:00") }
    it("midnight")    { expect(by_name[:midnight][:startsAt]).to    eq("2026-06-23 00:00") }
    it("explicit pm") { expect(by_name[:explicit_pm][:startsAt]).to eq("2026-06-22 15:00") }
    it("explicit am") { expect(by_name[:explicit_am][:startsAt]).to eq("2026-06-23 09:00") }
  end

  describe "duration parsing (mirrors jarvis/durations)" do
    it("for 20m") { expect(by_name[:dur_for_20m][:durationMin]).to eq(20) }
    it("for an hour") { expect(by_name[:dur_for_an_hour][:durationMin]).to eq(60) }
    it("half hour") { expect(by_name[:dur_half_hour][:durationMin]).to eq(30) }
    it("compound 1h30m") { expect(by_name[:dur_compound][:durationMin]).to eq(90) }
    it("no leading 'for' (30 minute walk)") { expect(by_name[:dur_no_for][:durationMin]).to eq(30) }
    it("trailing duration") { expect(by_name[:dur_minute_at_end][:durationMin]).to eq(20) }

    it("strips duration so it doesn't bleed into the name") do
      expect(by_name[:dur_compound][:name]).to eq("Hospital visit")
      expect(by_name[:dur_no_for][:name]).to   eq("walk")
    end

    it("ignores duration-like substrings inside words (ham, 9am, Birmingham)") do
      # Pure-probe cases — call extractDuration directly. These mirror the
      # Ruby-side Jarvis::Durations specs.
      expect(by_name[:dur_probe_ham]).to   eq(minutes: 0)
      expect(by_name[:dur_probe_9am]).to   eq(minutes: 0)
      expect(by_name[:dur_probe_empty]).to eq(minutes: 0)
    end

    it("recognizes compound 1h30m as 90 minutes via extractDuration") do
      expect(by_name[:dur_probe_1h30m]).to eq(minutes: 90)
    end

    it("'half hour' alone is 30 minutes via extractDuration") do
      expect(by_name[:dur_probe_half]).to eq(minutes: 30)
    end
  end

  describe "relative offsets" do
    it("'in 3 hours' from 10:23 → 13:23") do
      expect(by_name[:rel_in_3_hours][:startsAt]).to eq("2026-06-22 13:23")
    end
    it("'in 30 minutes' from 10:23 → 10:53") do
      expect(by_name[:rel_in_30_min][:startsAt]).to eq("2026-06-22 10:53")
    end
    it("'45 minutes from now' from 10:23 → 11:08") do
      expect(by_name[:rel_from_now][:startsAt]).to eq("2026-06-22 11:08")
    end
    it("'in a week' uses next-half-hour as the base time (day-level offset)") do
      # 10:23 → next half-hour = 10:30, then + 1 week = same time next Mon.
      expect(by_name[:rel_in_a_week][:startsAt]).to eq("2026-06-29 10:30")
    end
  end

  describe "weak day words (require a qualifier)" do
    it("'this evening' → 6pm today") do
      expect(by_name[:this_evening][:startsAt]).to eq("2026-06-22 18:00")
    end
    it("'tomorrow morning' → 8am tomorrow") do
      expect(by_name[:tomorrow_morning][:startsAt]).to eq("2026-06-23 08:00")
    end
    it("'in the afternoon' → 2pm today") do
      expect(by_name[:in_the_afternoon][:startsAt]).to eq("2026-06-22 14:00")
    end
  end

  describe "weekday hints" do
    it("'next Monday' → next Monday at the next-half-hour default") do
      # Mon Jun 22 → next Mon = Jun 29. Default at 10:23 → snap to 10:30.
      expect(by_name[:next_monday][:startsAt]).to eq("2026-06-29 10:30")
    end
    it("'Friday at 2' → coming Friday at 2pm (PM heuristic)") do
      expect(by_name[:bare_friday][:startsAt]).to eq("2026-06-26 14:00")
    end
  end

  describe "date forms" do
    it("'on the 25th' (still future this month) → Jun 25") do
      expect(by_name[:ordinal_this_month][:startsAt]).to eq("2026-06-25 10:30")
    end

    # This is the user's "on the 16th isn't working" complaint, JS side.
    it("'on the 16th' (already passed this month) → July 16" ) do
      expect(by_name[:ordinal_next_month][:startsAt]).to eq("2026-07-16 10:30")
    end

    it("'on the 30th' from Feb → Mar 30 (Feb has no 30)") do
      # FEB_05 sets now to 2026-02-05 9:00; next half-hour from 9:00
      # is 9:30.
      expect(by_name[:ordinal_feb_30][:startsAt]).to eq("2026-03-30 09:30")
    end

    it("'June 24' → Jun 24 this year") do
      expect(by_name[:month_day][:startsAt]).to eq("2026-06-24 10:30")
    end
    it("abbreviated month 'Jul 4'") do
      expect(by_name[:abbr_month_day][:startsAt]).to eq("2026-07-04 10:30")
    end
    it("month + day + explicit year") do
      expect(by_name[:month_day_with_year][:startsAt]).to eq("2027-01-15 10:30")
    end
    it("'7/4' slash format") do
      expect(by_name[:slash_date][:startsAt]).to eq("2026-07-04 10:30")
    end
  end

  describe "location parsing" do
    it "splits 'at Costco' from the event name" do
      r = by_name[:loc_costco]
      expect(r[:name]).to eq("Groceries")
      expect(r[:location]).to eq("Costco")
    end

    it "keeps multi-word capitalized locations intact ('Lucky Ones')" do
      r = by_name[:loc_lucky_ones]
      expect(r[:name]).to eq("Show")
      expect(r[:location]).to eq("Lucky Ones")
    end

    it "handles time + location in the same input ('at 6pm at Texas Roadhouse')" do
      r = by_name[:loc_with_time]
      expect(r[:name]).to eq("Dinner")
      expect(r[:location]).to eq("Texas Roadhouse")
      expect(r[:startsAt]).to eq("2026-06-22 18:00")
    end

    it "handles day + time + location" do
      r = by_name[:loc_with_day_and_time]
      expect(r[:name]).to eq("Meeting")
      expect(r[:location]).to eq("the office")
      expect(r[:startsAt]).to eq("2026-06-26 14:00")
    end

    it "extracts location even without a time hint" do
      r = by_name[:loc_no_time]
      expect(r[:name]).to eq("Lunch")
      expect(r[:location]).to eq("Sam's")
      # Default next-half-hour still applies.
      expect(r[:startsAt]).to eq("2026-06-22 10:30")
    end

    it "extracts location alongside a relative offset" do
      r = by_name[:loc_with_relative]
      expect(r[:name]).to eq("Stretch")
      expect(r[:location]).to eq("the gym")
      expect(r[:startsAt]).to eq("2026-06-22 10:53")
    end

    it "does NOT misread 'at noon' as a location" do
      r = by_name[:loc_noon_is_time]
      expect(r[:name]).to eq("Lunch")
      expect(r[:location]).to be_nil
      expect(r[:startsAt]).to eq("2026-06-22 12:00")
    end
  end

  describe "all-day events" do
    it "`all day Saturday` → midnight Saturday, allDay=true, 24-hr duration" do
      r = by_name[:allday_single]
      expect(r[:allDay]).to be true
      expect(r[:name]).to eq("Birthday")
      expect(r[:startsAt]).to eq("2026-06-27 00:00")
      expect(r[:durationMin]).to eq(1440)
    end

    it "hyphenated `all-day` matches too" do
      expect(by_name[:allday_hyphenated][:allDay]).to be true
    end

    it "`all day for 3 days` → 3-day span starting at today's midnight" do
      r = by_name[:allday_multi_day]
      expect(r[:allDay]).to be true
      expect(r[:durationMin]).to eq(4320) # 3 * 1440
      # Default day when none given is today; the always-future gate
      # checks `end <= now`, and the event's end (Thu Jun 25 midnight)
      # is in the future, so start stays at Mon Jun 22 midnight.
      expect(r[:startsAt]).to eq("2026-06-22 00:00")
      expect(r[:endsAt]).to   eq("2026-06-25 00:00")
    end

    it "clock-time hint is ignored when `all day` is present" do
      r = by_name[:allday_time_ignored]
      expect(r[:allDay]).to be true
      # Tuesday Jun 23, anchored at midnight — NOT 9am.
      expect(r[:startsAt]).to eq("2026-06-23 00:00")
    end

    it "all-day today after noon stays on today (event still happening)" do
      r = by_name[:allday_today_after_noon]
      expect(r[:allDay]).to be true
      expect(r[:startsAt]).to eq("2026-06-22 00:00")
    end
  end

  describe "next-half-hour default-time snapping" do
    # Locks every edge of the rounding rule so a future change to the
    # helper can't silently shift the default scheduling moment.
    it("10:00 → 10:30") { expect(by_name[:half_at_10_00][:startsAt]).to eq("2026-06-22 10:30") }
    it("10:01 → 10:30") { expect(by_name[:half_at_10_01][:startsAt]).to eq("2026-06-22 10:30") }
    it("10:29 → 10:30") { expect(by_name[:half_at_10_29][:startsAt]).to eq("2026-06-22 10:30") }
    it("10:30 → 11:00") { expect(by_name[:half_at_10_30][:startsAt]).to eq("2026-06-22 11:00") }
    it("10:31 → 11:00") { expect(by_name[:half_at_10_31][:startsAt]).to eq("2026-06-22 11:00") }
    it("10:59 → 11:00") { expect(by_name[:half_at_10_59][:startsAt]).to eq("2026-06-22 11:00") }

    it "applies to day-level relative offsets ('doit in 4 days' at 1:12pm → Fri 1:30pm)" do
      r = by_name[:rel_in_4_days_user]
      expect(r[:name]).to eq("doit")
      expect(r[:startsAt]).to eq("2026-06-26 13:30")
    end
  end

  describe "nearest-future ambiguous hour (skip 12am-5am)" do
    it "`Storage at 9` at 10:23am → 9pm today (9am already passed)" do
      expect(by_name[:ambig_9_morning][:startsAt]).to eq("2026-06-22 21:00")
    end

    it "`Storage at 9` at 7am → 9am today (still future, nearer than 9pm)" do
      expect(by_name[:ambig_9_early_morning][:startsAt]).to eq("2026-06-23 09:00")
    end

    it "`Storage at 3` at 4pm → 3pm tomorrow (3am tomorrow falls in skip window)" do
      expect(by_name[:ambig_3_after_3pm][:startsAt]).to eq("2026-06-23 15:00")
    end

    it "`Storage at 12` at 1pm → noon tomorrow (midnight tonight is in skip window)" do
      expect(by_name[:ambig_12_after_noon][:startsAt]).to eq("2026-06-23 12:00")
    end

    it "`tomorrow at 8` at 6pm → 8am tomorrow (nearer than 8pm on the target day)" do
      expect(by_name[:ambig_tomorrow_at_8][:startsAt]).to eq("2026-06-23 08:00")
    end
  end

  describe "from-to range" do
    it "`from 8 to 10` resolves to both ends PM (under skip+nearest-future)" do
      r = by_name[:range_from_8_to_10]
      expect(r[:startsAt]).to    eq("2026-06-22 20:00")
      expect(r[:endsAt]).to      eq("2026-06-22 22:00")
      expect(r[:durationMin]).to eq(120)
    end

    it "`from 8 until 10` works the same as `from 8 to 10`" do
      expect(by_name[:range_from_8_until_10][:startsAt]).to eq("2026-06-22 20:00")
      expect(by_name[:range_from_8_until_10][:endsAt]).to   eq("2026-06-22 22:00")
    end

    it "explicit PM on end propagates to ambiguous start (`from 8 to 10pm`)" do
      r = by_name[:range_from_8_to_10pm]
      expect(r[:startsAt]).to eq("2026-06-22 20:00")
      expect(r[:endsAt]).to   eq("2026-06-22 22:00")
    end

    it "explicit AM on start propagates to ambiguous end (`from 8am to 10`)" do
      r = by_name[:range_from_8am_to_10]
      # 8am today is past (10:23), so the always-future gate rolls both
      # ends to tomorrow.
      expect(r[:startsAt]).to eq("2026-06-23 08:00")
      expect(r[:endsAt]).to   eq("2026-06-23 10:00")
    end

    it "`from 9am to 11am` keeps both ends AM" do
      r = by_name[:range_from_9am_to_11am]
      # 11am hasn't passed yet at 10:23, so it stays today.
      expect(r[:startsAt]).to eq("2026-06-22 09:00")
      expect(r[:endsAt]).to   eq("2026-06-22 11:00")
    end

    it "`from noon to 3pm` honors the noon word" do
      r = by_name[:range_from_noon_to_3pm]
      expect(r[:startsAt]).to eq("2026-06-22 12:00")
      expect(r[:endsAt]).to   eq("2026-06-22 15:00")
    end

    it "`from 8:30 to 10pm` parses minutes on the start" do
      r = by_name[:range_from_8_30_to_10]
      expect(r[:startsAt]).to eq("2026-06-22 20:30")
      expect(r[:endsAt]).to   eq("2026-06-22 22:00")
    end

    it "overnight `from 11pm to 1am` rolls the end onto the next day" do
      r = by_name[:range_overnight]
      expect(r[:startsAt]).to eq("2026-06-22 23:00")
      expect(r[:endsAt]).to   eq("2026-06-23 01:00")
    end

    it "day hint + range stays on that day (`Show from 7 to 9 on Friday`)" do
      r = by_name[:range_with_day_hint]
      # Nearest-future picker sees AM on Friday as future + earlier
      # than PM (7 is outside the 12am-5am skip window), so it lands
      # at 7am Friday. User adds `am/pm` explicitly when they mean PM.
      expect(r[:startsAt]).to eq("2026-06-26 07:00")
      expect(r[:endsAt]).to   eq("2026-06-26 09:00")
      expect(r[:name]).to     eq("Show")
    end
  end

  describe "agenda routing" do
    it "leading agenda name routes the event and strips itself + `to`" do
      r = by_name[:agenda_routes_costco]
      expect(r[:agendaId]).to eq(42)
      expect(r[:name]).to     eq("Storage")
      expect(r[:startsAt]).to eq("2026-06-22 17:00")
    end

    it "no agenda matches → agendaId nil and the input stays intact" do
      r = by_name[:agenda_no_match]
      expect(r[:agendaId]).to be_nil
      # "Drive to Costco" is the event name; "at 5" is the time.
      expect(r[:name]).to     eq("Drive to Costco")
      expect(r[:startsAt]).to eq("2026-06-22 17:00")
    end

    it "longest agenda name wins over a substring match" do
      r = by_name[:agenda_longest_wins]
      expect(r[:agendaId]).to eq(7)
      expect(r[:name]).to     eq("Disneyland")
    end

    it "agenda match is case-insensitive" do
      r = by_name[:agenda_case_insensitive]
      expect(r[:agendaId]).to eq(42)
      expect(r[:name]).to     eq("Storage")
    end
  end

  describe "errors" do
    it "empty input is rejected" do
      expect(by_name[:empty]).to eq(ok: false, error: "empty")
    end
    it "input with no name (only time) is rejected" do
      expect(by_name[:no_name_only_time]).to eq(ok: false, error: "missing_name")
    end
  end
end
