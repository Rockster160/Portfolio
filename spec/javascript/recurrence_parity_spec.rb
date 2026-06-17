require "rails_helper"
require "json"
require "open3"

# Parity guard: every recurrence rule that AgendaSchedule#matches?
# (Ruby) supports MUST produce identical occurrence sets when run
# through the JS expander in app/javascript/src/agenda_store/
# recurrence.js. The store-driven FE renders any date the user
# navigates to without a server round-trip, so a divergence between
# these two implementations would show up as missing/extra events on
# specific dates — exactly the kind of silent data corruption a calendar
# can't have.
#
# Add a fixture for every recurrence shape; if the Ruby logic gains a
# new branch, add the matching JS code AND the fixture before merging.
RSpec.describe "Recurrence parity (Ruby vs JS expander)" do
  let(:user)   { create(:user) }
  let(:agenda) { create(:agenda, user: user) }

  def schedule(**attrs)
    defaults = {
      agenda:           agenda,
      name:             "T",
      kind:             "task",
      start_time:       "09:00",
      duration_minutes: nil,
      starts_on:        Date.new(2026, 1, 1),
    }
    create(:agenda_schedule, defaults.merge(attrs))
  end

  def ruby_matches(sched, from, to)
    (from..to).each_with_object([]) { |d, acc| acc << d.iso8601 if sched.matches?(d) }
  end

  def js_matches(cases)
    payload = { cases: cases }.to_json
    runner  = Rails.root.join("spec", "javascript", "parity_runner.js").to_s
    stdout, stderr, status = Open3.capture3("node", runner, stdin_data: payload)
    raise "parity_runner failed: #{stderr}" unless status.success?
    JSON.parse(stdout).fetch("results")
  end

  it "matches across every supported recurrence shape" do
    fixtures = [
      [
        "daily",
        schedule(recurrence: { "freq" => "daily" }),
        Date.new(2026, 1, 1), Date.new(2026, 1, 31),
      ],
      [
        "weekdays",
        schedule(recurrence: { "freq" => "weekdays" }),
        Date.new(2026, 1, 1), Date.new(2026, 2, 28),
      ],
      [
        "weekly_by_day",
        schedule(recurrence: { "freq" => "weekly", "by_day" => %w[mon wed fri] }),
        Date.new(2026, 1, 1), Date.new(2026, 3, 31),
      ],
      [
        "monthly_by_month_day",
        schedule(recurrence: { "freq" => "monthly", "by_month_day" => [1, 15] }),
        Date.new(2026, 1, 1), Date.new(2026, 6, 30),
      ],
      [
        "monthly_last_day",
        schedule(recurrence: { "freq" => "monthly", "by_month_day" => [-1] }),
        Date.new(2026, 1, 1), Date.new(2027, 6, 30),
      ],
      [
        "monthly_nth_weekday",
        schedule(recurrence: { "freq" => "monthly", "by_day" => %w[tue], "by_set_pos" => 3 }),
        Date.new(2026, 1, 1), Date.new(2026, 12, 31),
      ],
      [
        "monthly_last_weekday",
        schedule(recurrence: { "freq" => "monthly", "by_day" => %w[fri], "by_set_pos" => -1 }),
        Date.new(2026, 1, 1), Date.new(2026, 12, 31),
      ],
      [
        "yearly",
        schedule(starts_on: Date.new(2026, 2, 14), recurrence: { "freq" => "yearly" }),
        Date.new(2026, 1, 1), Date.new(2030, 12, 31),
      ],
      [
        "custom_every_3_days",
        schedule(recurrence: { "freq" => "custom", "unit" => "day", "interval" => 3 }),
        Date.new(2026, 1, 1), Date.new(2026, 2, 28),
      ],
      [
        "custom_every_2_weeks",
        schedule(starts_on: Date.new(2026, 1, 5), recurrence: { "freq" => "custom", "unit" => "week", "interval" => 2 }),
        Date.new(2026, 1, 1), Date.new(2026, 6, 30),
      ],
      [
        "custom_every_2_months_by_month_day",
        schedule(
          recurrence: { "freq" => "custom", "unit" => "month", "interval" => 2, "by_month_day" => [10, 20] }
        ),
        Date.new(2026, 1, 1), Date.new(2027, 1, 31),
      ],
      [
        "until_on_caps_range",
        schedule(
          recurrence: { "freq" => "daily" },
          until_on:   Date.new(2026, 1, 10),
        ),
        Date.new(2026, 1, 1), Date.new(2026, 1, 31),
      ],
      [
        "excluded_dates_skip",
        schedule(recurrence: { "freq" => "daily", "excluded_dates" => ["2026-01-05", "2026-01-12"] }),
        Date.new(2026, 1, 1), Date.new(2026, 1, 31),
      ],
      [
        "starts_on_blocks_earlier_dates",
        schedule(starts_on: Date.new(2026, 6, 1), recurrence: { "freq" => "daily" }),
        Date.new(2026, 1, 1), Date.new(2026, 6, 30),
      ],
    ]

    cases = fixtures.map { |name, sched, _from, _to|
      { name: name, schedule: sched.serialize_for_client.as_json,
        from: _from.iso8601, to: _to.iso8601 }
    }
    expected = fixtures.map { |name, sched, from, to|
      { "name" => name, "matches" => ruby_matches(sched, from, to) }
    }
    actual = js_matches(cases)

    expected.zip(actual).each do |exp, act|
      expect(act["name"]).to eq(exp["name"])
      expect(act["matches"]).to eq(exp["matches"]), "mismatch for #{exp["name"]}:\n" \
        "  ruby: #{exp["matches"].inspect}\n  js:   #{act["matches"].inspect}"
    end
  end
end
