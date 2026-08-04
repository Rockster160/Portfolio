require "rails_helper"

# The compact string the model writes, turned into the rule Recurrence reads.
RSpec.describe Buddy::RepeatSpec do
  # A Tuesday, so "every 2 weeks" has an unambiguous weekday to anchor on.
  let(:today) { Date.new(2026, 3, 3) }

  def parse(spec)
    described_class.parse(spec, on: today)
  end

  it "reads the simple ones" do
    expect(parse("daily:09:00")).to include("freq" => "daily", "at" => "09:00")
    expect(parse("weekdays:07:54")).to include("freq" => "weekdays", "at" => "07:54")
    expect(parse("yearly:08:00")).to include("freq" => "yearly", "at" => "08:00")
  end

  it "reads a weekly, however the day is spelled" do
    expect(parse("weekly:wednesday:20:00")).to include("freq" => "weekly", "by_day" => ["wed"])
    expect(parse("weekly:weds:20:00")).to include("by_day" => ["wed"])
  end

  it "takes several weekdays at once" do
    expect(parse("weekly:mon,wed,fri:07:30")).to include("by_day" => %w[mon wed fri])
  end

  it "reads a day of the month" do
    expect(parse("monthly:15:09:00")).to include("freq" => "monthly", "by_month_day" => [15])
  end

  # The request that started this. "Every second Tuesday" is two different
  # things and they aren't the same days.
  it "reads the second Tuesday of the month" do
    expect(parse("monthly:2-tuesday:10:00")).to include(
      "freq" => "monthly", "by_set_pos" => 2, "by_day" => ["tue"],
    )
  end

  it "reads every other week, anchored to the day it was set" do
    expect(parse("every:2-weeks:10:00")).to include(
      "freq" => "custom", "interval" => 2, "unit" => "week", "starts_on" => "2026-03-03",
    )
  end

  it "reads the last Friday of the month" do
    expect(parse("monthly:last-friday:17:00")).to include("by_set_pos" => -1, "by_day" => ["fri"])
  end

  it "reads a word for the ordinal as readily as a digit" do
    expect(parse("monthly:second-tuesday:10:00")).to include("by_set_pos" => 2)
  end

  # Nil rather than a half-built rule: the tool says it couldn't read the spec,
  # which beats setting a reminder for a time nobody asked for.
  describe "one it can't read" do
    it "refuses an unknown frequency" do
      expect(parse("fortnightly:09:00")).to be_nil
    end

    it "refuses a missing or malformed clock" do
      expect(parse("daily")).to be_nil
      expect(parse("daily:9")).to be_nil
      expect(parse("daily:25:00")).to be_nil
      expect(parse("weekly:monday")).to be_nil
    end

    it "refuses a weekday that isn't one" do
      expect(parse("weekly:someday:09:00")).to be_nil
    end

    it "refuses an interval with no unit" do
      expect(parse("every:2:09:00")).to be_nil
      expect(parse("every:2-fortnights:09:00")).to be_nil
    end

    it "refuses a day of the month that doesn't exist" do
      expect(parse("monthly:40:09:00")).to be_nil
    end

    it "is nil for nothing at all" do
      expect(parse("")).to be_nil
      expect(parse(nil)).to be_nil
    end
  end

  # Whatever the spec produces has to be something the matcher can actually
  # walk, or the reminder is set and never comes round.
  describe "what it produces" do
    it "resolves to a real next date" do
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
end
