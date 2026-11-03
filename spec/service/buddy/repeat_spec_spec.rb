require "rails_helper"

# The compact string the model writes, turned into the rule Recurrence reads.
RSpec.describe Buddy::RepeatSpec do
  # A Tuesday, so "every 2 weeks" has an unambiguous weekday to anchor on.
  let(:today) { Date.new(2026, 3, 3) }

  def parse(spec)
    described_class.parse(spec, on: today)
  end

  # "Every second Tuesday" is two different things and they aren't the same
  # days: by_set_pos for the month, an interval for every other week.
  it "reads each shape into its rule", :aggregate_failures do
    [
      ["daily:09:00", { "freq" => "daily", "at" => "09:00" }],
      ["weekdays:07:54", { "freq" => "weekdays", "at" => "07:54" }],
      ["yearly:08:00", { "freq" => "yearly", "at" => "08:00" }],
      ["weekly:wednesday:20:00", { "freq" => "weekly", "by_day" => ["wed"] }],
      ["weekly:weds:20:00", { "by_day" => ["wed"] }],
      ["weekly:mon,wed,fri:07:30", { "by_day" => %w[mon wed fri] }],
      ["monthly:15:09:00", { "freq" => "monthly", "by_month_day" => [15] }],
      ["monthly:2-tuesday:10:00", { "freq" => "monthly", "by_set_pos" => 2, "by_day" => ["tue"] }],
      ["monthly:second-tuesday:10:00", { "by_set_pos" => 2 }],
      ["monthly:last-friday:17:00", { "by_set_pos" => -1, "by_day" => ["fri"] }],
      ["every:2-weeks:10:00", { "freq" => "custom", "interval" => 2, "unit" => "week", "starts_on" => "2026-03-03" }],
      ["every:3-days:10:00", { "freq" => "custom", "unit" => "day" }],
    ].each do |spec, expected|
      expect(parse(spec)).to include(expected), spec
    end
  end

  # Translated into the `every_minutes` stepping BuddyReminder#slots_on already
  # walks, from `at` up to `until_at`, rather than a `unit` nothing knows how to
  # advance. Past half a day it's a daily wearing a costume.
  it "reads a sub-day interval as minutes on a daily, within half a day", :aggregate_failures do
    rule = parse("every:30-minutes:14:00")
    expect(rule).to include("freq" => "daily", "at" => "14:00", "every_minutes" => 30, "until_at" => "23:59")
    expect(rule).not_to include("unit", "interval")

    expect(parse("every:2-hours:08:00")).to include("every_minutes" => 120)
    expect(parse("every:45-min:09:00")).to include("every_minutes" => 45)
    expect(parse("every:6-hrs:09:00")).to include("every_minutes" => 360)

    %w[every:13-hours:09:00 every:800-minutes:09:00 every:0-minutes:09:00].each do |spec|
      expect(parse(spec)).to be_nil, spec
    end
  end

  # Nil rather than a half-built rule: the tool says it couldn't read the spec,
  # which beats setting a reminder for a time nobody asked for.
  it "refuses anything it can't read", :aggregate_failures do
    [
      "fortnightly:09:00",
      "daily", 
"daily:9", 
"daily:25:00", 
"weekly:monday",
      "weekly:someday:09:00",
      "every:2:09:00", 
"every:2-fortnights:09:00",
      "monthly:40:09:00",
      "", 
nil,
    ].each do |spec|
      expect(parse(spec)).to be_nil, spec.inspect
    end
  end

  # Whatever the spec produces has to be something the matcher can actually
  # walk, or the reminder is set and never comes round.
  it "produces rules that resolve to a real next date", :aggregate_failures do
    user  = create(:user)
    convo = user.byte_conversations.create!(mode: :buddy)

    %w[daily:09:00 weekdays:07:54 weekly:mon,fri:18:00 monthly:2-tuesday:10:00 every:2-weeks:10:00].each do |spec|
      reminder = BuddyReminder.new(
        user: user, byte_conversation: convo, body: "x",
        fire_at: Time.current, recurrence: parse(spec)
      )
      expect(reminder.next_fire_at).to be_present, "expected #{spec} to come round again"
    end
  end
end
