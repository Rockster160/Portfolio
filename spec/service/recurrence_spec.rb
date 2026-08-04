require "rails_helper"

# The rule engine on its own, with no calendar and no reminder around it.
#
# AgendaSchedule's specs cover it through the calendar and
# spec/javascript/recurrence_parity_spec.rb guards it against the JS port; this
# is the one that says what the rules MEAN, including the shapes BuddyReminder
# gained by sharing them.
RSpec.describe Recurrence do
  # A Thursday, so weekday-anchored rules have something unambiguous to hang on.
  let(:start) { Date.new(2026, 1, 1) }

  def rule(hash, starts_on: start, until_on: nil)
    described_class.new(hash, starts_on: starts_on, until_on: until_on)
  end

  def dates(hash, from: start, to: start + 60, **opts)
    rule(hash, **opts).between(from, to).map(&:to_s)
  end

  describe "the simple frequencies" do
    it "matches every day" do
      expect(dates({ freq: :daily }, to: start + 2)).to eq(%w[2026-01-01 2026-01-02 2026-01-03])
    end

    it "matches Monday to Friday only" do
      # Jan 1 2026 is a Thursday, so the run is Thu, Fri, then skip the weekend.
      expect(dates({ freq: :weekdays }, to: start + 5)).to eq(%w[2026-01-01 2026-01-02 2026-01-05 2026-01-06])
    end

    it "matches the named weekdays" do
      expect(dates({ freq: :weekly, by_day: %w[mon wed] }, to: start + 13)).to eq(
        %w[2026-01-05 2026-01-07 2026-01-12 2026-01-14],
      )
    end

    it "falls back to the start date's weekday when none are named" do
      expect(dates({ freq: :weekly }, to: start + 14)).to eq(%w[2026-01-01 2026-01-08 2026-01-15])
    end

    it "matches the named days of the month" do
      expect(dates({ freq: :monthly, by_month_day: [1, 15] }, to: start + 45)).to eq(
        %w[2026-01-01 2026-01-15 2026-02-01 2026-02-15],
      )
    end

    it "reads -1 as the last day of the month, whatever length it is" do
      expect(dates({ freq: :monthly, by_month_day: [-1] }, to: start + 90)).to eq(
        %w[2026-01-31 2026-02-28 2026-03-31],
      )
    end

    it "matches one date a year" do
      expect(dates({ freq: :yearly }, to: start + 400)).to eq(%w[2026-01-01 2027-01-01])
    end
  end

  # The two things "every second Tuesday" can mean. Both are real requests and
  # they are not the same set of days, which is exactly why the rule has to be
  # able to say which one it is.
  describe "every second Tuesday" do
    it "reads as the 2nd Tuesday of each month with by_set_pos" do
      expect(dates({ freq: :monthly, by_set_pos: 2, by_day: %w[tue] }, to: start + 90)).to eq(
        %w[2026-01-13 2026-02-10 2026-03-10],
      )
    end

    it "reads as every other Tuesday with a custom weekly interval" do
      tuesday = Date.new(2026, 1, 6)
      expect(dates({ freq: :custom, interval: 2, unit: :week }, starts_on: tuesday, from: tuesday, to: tuesday + 42)).to eq(
        %w[2026-01-06 2026-01-20 2026-02-03 2026-02-17],
      )
    end
  end

  describe "nth weekday of the month" do
    it "matches the last Friday" do
      expect(dates({ freq: :monthly, by_set_pos: -1, by_day: %w[fri] }, to: start + 90)).to eq(
        %w[2026-01-30 2026-02-27 2026-03-27],
      )
    end

    it "ignores by_month_day when a set position is given" do
      rows = dates({ freq: :monthly, by_set_pos: 1, by_day: %w[mon], by_month_day: [20] }, to: start + 45)
      expect(rows).to eq(%w[2026-01-05 2026-02-02])
    end
  end

  describe "custom intervals" do
    it "counts days from the start" do
      expect(dates({ freq: :custom, interval: 3, unit: :day }, to: start + 9)).to eq(
        %w[2026-01-01 2026-01-04 2026-01-07 2026-01-10],
      )
    end

    it "counts months from the start" do
      expect(dates({ freq: :custom, interval: 2, unit: :month }, to: start + 130)).to eq(
        %w[2026-01-01 2026-03-01 2026-05-01],
      )
    end

    it "treats an interval below one as every time" do
      expect(dates({ freq: :custom, interval: 0, unit: :day }, to: start + 2)).to eq(
        %w[2026-01-01 2026-01-02 2026-01-03],
      )
    end
  end

  describe "the window" do
    it "never matches before the start" do
      expect(rule({ freq: :daily }).matches?(start - 1)).to be(false)
    end

    it "stops at the end date" do
      expect(dates({ freq: :daily }, until_on: start + 1, to: start + 10)).to eq(%w[2026-01-01 2026-01-02])
    end

    it "skips a date that was struck out" do
      excluded = { freq: :daily, excluded_dates: ["2026-01-02"] }
      expect(dates(excluded, to: start + 2)).to eq(%w[2026-01-01 2026-01-03])
    end

    it "ignores an unparseable exclusion instead of dropping every date" do
      expect(dates({ freq: :daily, excluded_dates: ["not a date"] }, to: start + 1)).to eq(
        %w[2026-01-01 2026-01-02],
      )
    end
  end

  describe "#next_on_or_after" do
    it "returns the day itself when it already matches" do
      expect(rule({ freq: :daily }).next_on_or_after(start)).to eq(start)
    end

    it "walks forward to the next one that does" do
      expect(rule({ freq: :weekly, by_day: %w[mon] }).next_on_or_after(start)).to eq(Date.new(2026, 1, 5))
    end

    it "never returns a date before the rule starts" do
      expect(rule({ freq: :daily }).next_on_or_after(start - 10)).to eq(start)
    end

    it "gives up rather than hanging on a rule that matches nothing" do
      expect(rule({ freq: :daily }, until_on: start - 1).next_on_or_after(start)).to be_nil
    end
  end

  describe "#date_of_occurrence" do
    it "finds the date the Nth one lands on" do
      expect(rule({ freq: :weekdays }).date_of_occurrence(5)).to eq(Date.new(2026, 1, 7))
    end

    it "is nil for a count of nothing" do
      expect(rule({ freq: :daily }).date_of_occurrence(0)).to be_nil
    end
  end

  describe "a rule it doesn't recognise" do
    it "matches nothing rather than guessing" do
      expect(rule({ freq: :fortnightly }).matches?(start)).to be(false)
      expect(rule({ freq: :fortnightly })).not_to be_valid_freq
    end

    it "defaults a missing freq to daily, which is what the calendar always did" do
      expect(rule({}).freq).to eq(:daily)
      expect(rule({}).matches?(start)).to be(true)
    end
  end
end
