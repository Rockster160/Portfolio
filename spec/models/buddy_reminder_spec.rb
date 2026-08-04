require "rails_helper"

RSpec.describe BuddyReminder do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:zone)  { ActiveSupport::TimeZone[user.timezone] }

  # `created_at` is where an interval counts FROM when the rule doesn't name a
  # start of its own, so it has to be pinned for a spec that asserts on
  # particular dates - a reminder can't fire before it was set.
  def reminder(recurrence, body: "Grab my Loops")
    described_class.create!(
      user: user, byte_conversation: convo, body: body,
      fire_at: zone.local(2026, 1, 1, 9, 0), recurrence: recurrence,
      created_at: zone.local(2026, 1, 1, 9, 0)
    )
  end

  # A reminder used to carry four frequencies of its own - daily, weekdays,
  # weekly, monthly - with no interval, no nth-weekday and no end date. The
  # calendar had all of it. Sharing Recurrence is what closed that gap.
  describe "#next_fire_at" do
    def next_after(recurrence, from)
      reminder(recurrence).next_fire_at(from: zone.parse(from))
    end

    it "rolls a daily one forward once its hour has gone by" do
      at = next_after({ freq: :daily, at: "09:00" }, "2026-03-04 09:01")

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-05 09:00")
    end

    it "keeps today when the hour is still ahead" do
      at = next_after({ freq: :daily, at: "09:00" }, "2026-03-04 08:59")

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-04 09:00")
    end

    it "skips the weekend on weekdays" do
      # 2026-03-06 is a Friday, so the next weekday is Monday the 9th.
      at = next_after({ freq: :weekdays, at: "07:54" }, "2026-03-06 08:00")

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-09 07:54")
    end

    it "handles several named weekdays" do
      # 2026-03-04 is a Wednesday; next Monday-or-Wednesday after it is the 9th.
      at = next_after({ freq: :weekly, by_day: %w[mon wed], at: "18:00" }, "2026-03-04 19:00")

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-09 18:00")
    end

    # The request that started this: neither of these was expressible before.
    it "fires on the second Tuesday of the month" do
      at = next_after({ freq: :monthly, by_set_pos: 2, by_day: %w[tue], at: "10:00" }, "2026-03-01 00:00")

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-10 10:00")
    end

    it "fires every other Tuesday, counting from where it started" do
      rule = { freq: :custom, interval: 2, unit: :week, at: "10:00", starts_on: "2026-03-03" }
      at   = next_after(rule, "2026-03-04 00:00")

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-17 10:00")
    end

    it "fires on the last Friday of the month" do
      at = next_after({ freq: :monthly, by_set_pos: -1, by_day: %w[fri], at: "17:00" }, "2026-03-01 00:00")

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-27 17:00")
    end

    it "stops once the end date has passed" do
      rule = { freq: :daily, at: "09:00", until_on: "2026-03-05" }

      expect(next_after(rule, "2026-03-06 00:00")).to be_nil
    end

    it "skips a date that was struck out" do
      rule = { freq: :daily, at: "09:00", excluded_dates: ["2026-03-05"] }
      at   = next_after(rule, "2026-03-04 10:00")

      expect(at.strftime("%Y-%m-%d")).to eq("2026-03-06")
    end

    it "is nil for a one-off" do
      expect(reminder(nil).next_fire_at).to be_nil
    end
  end

  # A row written by the previous release has to keep firing through the
  # deploy, so the old vocabulary is translated on READ rather than only by the
  # migration that cleans it up.
  describe "the shape reminders used to store" do
    it "reads the old daily" do
      at = reminder({ kind: "daily", at: "21:30" }).next_fire_at(from: zone.parse("2026-03-04 22:00"))

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-05 21:30")
    end

    it "reads the old weekdays" do
      at = reminder({ kind: "weekdays", at: "07:54" }).next_fire_at(from: zone.parse("2026-03-06 08:00"))

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-09 07:54")
    end

    it "reads the old weekly, whose weekday was spelled out in full" do
      at = reminder({ kind: "weekly", weekday: "wednesday", at: "20:00" }).next_fire_at(from: zone.parse("2026-03-04 21:00"))

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-03-11 20:00")
    end

    it "reads the old monthly day-of-month" do
      at = reminder({ kind: "monthly", day: 15, at: "09:00" }).next_fire_at(from: zone.parse("2026-03-16 00:00"))

      expect(at.strftime("%Y-%m-%d %H:%M")).to eq("2026-04-15 09:00")
    end

    it "translates it into the shared vocabulary" do
      converted = reminder({ kind: "weekly", weekday: "wednesday", at: "20:00" }).normalized_recurrence

      expect(converted).to include("freq" => "weekly", "by_day" => ["wed"], "at" => "20:00")
    end
  end
end
