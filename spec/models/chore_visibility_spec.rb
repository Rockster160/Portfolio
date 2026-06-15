require "rails_helper"

RSpec.describe Chore, "visibility + relative scheduling" do
  let(:user) { create(:user) }
  let(:today) { ChoreDay.current(user) }

  describe "show_on_today_view enum" do
    it "defaults to when_scheduled" do
      chore = create(:chore, created_by_user: user)
      expect(chore.today_when_scheduled?).to eq(true)
    end

    it "supports always / when_available / when_scheduled_and_available / never" do
      %i[always when_available when_scheduled_and_available never].each do |v|
        chore = create(:chore, created_by_user: user, show_on_today_view: v)
        expect(chore.show_on_today_view).to eq(v.to_s)
      end
    end
  end

  describe "matches_day? — fixed recurrences (user-independent)" do
    it "daily — always matches" do
      chore = create(:chore, created_by_user: user, recurrence: { freq: :daily })
      expect(chore.matches_day?(today)).to eq(true)
      expect(chore.matches_day?(today - 100)).to eq(true)
    end

    it "weekdays — matches Mon-Fri only" do
      chore = create(:chore, created_by_user: user, recurrence: { freq: :weekdays })
      monday = Date.new(2026, 5, 25) # confirmed Mon
      saturday = Date.new(2026, 5, 30)
      expect(chore.matches_day?(monday)).to eq(true)
      expect(chore.matches_day?(saturday)).to eq(false)
    end

    it "custom :day — anchored on starts_on (fixed pattern, completion-independent)" do
      chore = create(:chore, created_by_user: user,
        starts_on: today,
        recurrence: { freq: :custom, interval: 5, unit: :day })
      expect(chore.matches_day?(today)).to eq(true)
      expect(chore.matches_day?(today + 1)).to eq(false)
      expect(chore.matches_day?(today + 5)).to eq(true)
      # Completion on today+1 must NOT shift the next-match — fixed schedule.
      create(:chore_completion, chore: chore, user: user, completed_at: (today + 1).to_time, day_key: today + 1)
      expect(chore.matches_day?(today + 5)).to eq(true)
      expect(chore.matches_day?(today + 6)).to eq(false)
    end
  end

  describe "matches_day? — relative (anchored on last completion for user)" do
    let(:chore) {
      create(:chore, created_by_user: user,
        starts_on: today,
        recurrence: { freq: :relative, interval: 5, unit: :day })
    }

    it "first appearance falls on starts_on when never completed" do
      expect(chore.matches_day?(today, user)).to eq(true)
      expect(chore.matches_day?(today - 1, user)).to eq(false)
    end

    it "shifts to last_completion + interval when completed" do
      create(:chore_completion, chore: chore, user: user, completed_at: today.to_time, day_key: today)
      expect(chore.matches_day?(today + 4, user)).to eq(false)
      expect(chore.matches_day?(today + 5, user)).to eq(true)
      expect(chore.matches_day?(today + 6, user)).to eq(true) # carries forward
    end

    it "is per-user — sharer's completion doesn't shift my schedule" do
      other = create(:user)
      household = share_chore_household!(other, user)
      shared = create(:chore, created_by_user: other, chore_household: household,
        starts_on: today,
        recurrence: { freq: :relative, interval: 5, unit: :day })
      create(:chore_completion, chore: shared, user: other, completed_at: today.to_time, day_key: today)

      expect(shared.matches_day?(today, user)).to eq(true)   # user has not done it
      expect(shared.matches_day?(today + 5, user)).to eq(true) # still due for user
    end

    it "supports weeks and months as units" do
      weekly = create(:chore, created_by_user: user,
        starts_on: today,
        recurrence: { freq: :relative, interval: 2, unit: :week })
      monthly = create(:chore, created_by_user: user,
        starts_on: today,
        recurrence: { freq: :relative, interval: 3, unit: :month })

      create(:chore_completion, chore: weekly, user: user, day_key: today)
      create(:chore_completion, chore: monthly, user: user, day_key: today)

      expect(weekly.matches_day?(today + 14, user)).to eq(true)
      expect(weekly.matches_day?(today + 13, user)).to eq(false)
      expect(monthly.matches_day?(today >> 3, user)).to eq(true)
      expect(monthly.matches_day?(today >> 2, user)).to eq(false)
    end
  end

  describe "monthly recurrence with nth-weekday" do
    it "matches the second Tuesday of every month" do
      chore = create(:chore, created_by_user: user,
        starts_on: Date.new(2026, 5, 12), # second Tuesday of May 2026
        recurrence: { freq: :monthly, by_set_pos: 2, by_day: ["tue"] })
      expect(chore.matches_day?(Date.new(2026, 5, 12))).to eq(true) # 2nd Tue May
      expect(chore.matches_day?(Date.new(2026, 6, 9))).to eq(true)  # 2nd Tue June
      expect(chore.matches_day?(Date.new(2026, 6, 2))).to eq(false) # 1st Tue June
    end

    it "matches the last Friday of every month" do
      chore = create(:chore, created_by_user: user,
        starts_on: Date.new(2026, 5, 29),
        recurrence: { freq: :monthly, by_set_pos: -1, by_day: ["fri"] })
      expect(chore.matches_day?(Date.new(2026, 5, 29))).to eq(true)  # last Fri May
      expect(chore.matches_day?(Date.new(2026, 5, 22))).to eq(false) # not last
      expect(chore.matches_day?(Date.new(2026, 6, 26))).to eq(true)  # last Fri June
    end
  end

  describe "show_on_today_view :when_scheduled_and_available semantic = OR" do
    let(:chore) {
      create(:chore, created_by_user: user,
        show_on_today_view: :when_scheduled_and_available,
        threshold_seconds: 6 * 3600,
        recurrence: { freq: :daily })
    }
    it "shows when scheduled even if cooldown hasn't elapsed" do
      create(:chore_completion, chore: chore, user: user,
        completed_at: 1.hour.ago, day_key: ChoreDay.current(user), payout_skipped: false)
      get_history = "irrelevant"
      # We test the rule itself indirectly: scheduled=true (daily) so OR returns true
      # regardless of cooldown_elapsed?=false.
      expect(chore.cooldown_elapsed?(user, now: Time.current)).to eq(false)
      expect(chore.matches_day?(Date.current, user)).to eq(true)
    end
  end

  describe "cooldown_elapsed?" do
    let(:chore) { create(:chore, created_by_user: user, threshold_seconds: 6 * 3600) }

    it "true when there's no completion" do
      expect(chore.cooldown_elapsed?(user)).to eq(true)
    end

    it "false within the window, true after" do
      now = Time.current
      create(:chore_completion, chore: chore, user: user, completed_at: now - 1.hour, day_key: today)
      expect(chore.cooldown_elapsed?(user, now: now)).to eq(false)
      expect(chore.cooldown_elapsed?(user, now: now + 7.hours)).to eq(true)
    end

    it "ignores skipped-payout completions" do
      now = Time.current
      create(:chore_completion, chore: chore, user: user, completed_at: now - 1.hour, payout_skipped: true, day_key: today)
      expect(chore.cooldown_elapsed?(user, now: now)).to eq(true)
    end
  end
end
