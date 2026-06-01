require "rails_helper"

RSpec.describe ChoreCompleter do
  let(:user) { create(:user) }

  it "pays full reward on the first completion" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5)
    result = described_class.new(chore, user).call
    expect(result.completion.paid_pebbles).to eq(5)
    expect(result).not_to be_skipped
  end

  describe "format_seconds (no decimals, two-unit)" do
    let(:completer) { described_class.new(create(:chore, created_by_user: user), user) }
    it "formats common durations without decimals" do
      expect(completer.send(:format_seconds, 30)).to eq("<1m")
      expect(completer.send(:format_seconds, 125)).to eq("2m")
      expect(completer.send(:format_seconds, 5421)).to eq("1h 30m")
      expect(completer.send(:format_seconds, 3 * 86_400)).to eq("3d")
      expect(completer.send(:format_seconds, 3 * 86_400 + 3700)).to eq("3d 1h")
      expect(completer.send(:format_seconds, 72 * 3600)).to eq("3d")
    end
  end

  it "skips payout inside the cooldown window without resetting the timer" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 5, threshold_seconds: 6 * 3600)
    base = Time.current
    travel_to(base) { described_class.new(chore, user).call }
    travel_to(base + 3.hours) {
      result = described_class.new(chore, user).call
      expect(result).to be_skipped
      expect(result.completion.paid_pebbles).to eq(0)
    }
    travel_to(base + 7.hours) {
      result = described_class.new(chore, user).call
      expect(result).not_to be_skipped
      expect(result.completion.paid_pebbles).to eq(5)
    }
  end

  it "applies hot-pick multiplier" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 4)
    create(:chore_hot_pick, chore: chore, multiplier: 2.0, day_key: ChoreDay.current(user))
    result = described_class.new(chore, user).call
    expect(result.completion.paid_pebbles).to eq(8)
    expect(result.completion.hot_multiplier).to eq(2.0)
  end

  it "increments streak across consecutive days; resets after a missed day" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 1)
    today = ChoreDay.current(user)
    travel_to(today.to_time + 12.hours) { described_class.new(chore, user).call }
    expect(ChoreStreak.find_by!(user: user, chore: chore).current_streak).to eq(1)

    travel_to((today + 1).to_time + 12.hours) { described_class.new(chore, user).call }
    expect(ChoreStreak.find_by!(user: user, chore: chore).current_streak).to eq(2)

    # Missed day(s); next completion resets to 1
    travel_to((today + 3).to_time + 12.hours) { described_class.new(chore, user).call }
    expect(ChoreStreak.find_by!(user: user, chore: chore).current_streak).to eq(1)
  end

  it "marks an outstanding goal achieved and awards its bonus pebbles" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 1)
    goal = ChoreGoal.create!(
      user:            user,
      name:            "First!",
      kind:            :total_completions,
      scope_mode:      :cumulative,
      target_value:    1,
      awarded_pebbles: 20,
    )
    result = described_class.new(chore, user).call
    expect(result.achieved_goals.map(&:id)).to eq([goal.id])
    expect(goal.reload.achieved_at).to be_present
    expect(user.chore_balance).to eq(1 + 20)
  end

  it "applies daily_pebbles streak bonus once threshold passed" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 10)
    create(:chore_streak_bonus,
      user:   user,
      chore:  nil,
      kind:   :daily_pebbles,
      config: { "levels" => [{ "threshold" => 5, "multiplier" => 2 }] })
    # First call earns 10 — the threshold for the bonus reads "pebbles
    # earned today BEFORE this completion", so the first call pays
    # straight 10. Second call: today's total now 10 ≥ 5, so 2× → 20.
    first = described_class.new(chore, user).call
    second = described_class.new(chore, user).call
    expect(first.completion.paid_pebbles).to eq(10)
    expect(second.completion.paid_pebbles).to eq(20)
  end

  describe "per-chore streak bonus scoping" do
    let(:acnh)  { create(:chore, created_by_user: user, name: "ACNH Chores", reward_pebbles: 1) }
    let(:other) { create(:chore, created_by_user: user, name: "Vitamins",    reward_pebbles: 1) }
    before do
      create(:chore_streak_bonus,
        user:   user,
        chore:  acnh,
        kind:   :chore_streak,
        config: { "levels" => [
          { "threshold" => 1, "multiplier" => 1 },
          { "threshold" => 2, "multiplier" => 2 },
          { "threshold" => 3, "multiplier" => 3 },
          { "threshold" => 4, "multiplier" => 4 },
          { "threshold" => 5, "multiplier" => 5 },
        ] })
    end

    it "applies the bonus when completing its chore" do
      result = described_class.new(acnh, user).call
      expect(result.completion.paid_pebbles).to eq(1)
    end

    it "does NOT apply the chore-specific bonus when completing a different chore" do
      result = described_class.new(other, user).call
      expect(result.completion.streak_multiplier).to eq(1.0)
      expect(result.completion.paid_pebbles).to eq(1)
    end

    it "caps at 5x once the streak hits 5+ consecutive days" do
      day = ChoreDay.current(user)
      ChoreStreak.create!(user: user, chore: acnh, current_streak: 4, last_completed_day: day - 1)
      result = described_class.new(acnh, user).call
      expect(result.completion.paid_pebbles).to eq(5)
    end

    it "still caps at 5x even at streak 10 (no level above threshold:5)" do
      day = ChoreDay.current(user)
      ChoreStreak.create!(user: user, chore: acnh, current_streak: 9, last_completed_day: day - 1)
      result = described_class.new(acnh, user).call
      expect(result.completion.paid_pebbles).to eq(5)
    end
  end

  describe "chore-agnostic pebble-threshold bonuses" do
    it "applies daily_pebbles bonus to any chore, regardless of which chore is being completed" do
      water  = create(:chore, created_by_user: user, name: "Water",  reward_pebbles: 10)
      dishes = create(:chore, created_by_user: user, name: "Dishes", reward_pebbles: 10)
      # Bonus has no chore_id — pebble-threshold kinds apply on any completion.
      create(:chore_streak_bonus,
        user:   user,
        chore:  nil,
        kind:   :daily_pebbles,
        config: { "levels" => [{ "threshold" => 5, "multiplier" => 2 }] })
      described_class.new(water, user).call # raises today total to 10
      after = described_class.new(dishes, user).call
      expect(after.completion.paid_pebbles).to eq(20)
    end
  end

  describe "additive streak bonus_pebbles" do
    it "adds the level's bonus_pebbles on top of the multiplied base" do
      chore = create(:chore, created_by_user: user, reward_pebbles: 10)
      create(:chore_streak_bonus,
        user: user, chore: chore, kind: :chore_streak,
        config: { "levels" => [{ "threshold" => 1, "multiplier" => 2, "bonus_pebbles" => 3 }] })

      result = described_class.new(chore, user).call
      expect(result.completion.paid_pebbles).to eq(23) # 10 * 2 + 3
      expect(result.completion.streak_multiplier).to eq(2.0)
      expect(result.completion.metadata["streak_bonus_pebbles"]).to eq(3)
      expect(result.completion.metadata["multipliers"].first).to include("bonus" => 3, "value" => 2)
    end

    it "treats bonuses additively across multiple active streak bonuses" do
      chore = create(:chore, created_by_user: user, reward_pebbles: 4)
      create(:chore_streak_bonus,
        user: user, chore: chore, kind: :chore_streak,
        config: { "levels" => [{ "threshold" => 1, "multiplier" => 1, "bonus_pebbles" => 2 }] })
      create(:chore_streak_bonus,
        user: user, chore: nil, kind: :daily_pebbles,
        config: { "levels" => [{ "threshold" => 0, "multiplier" => 1, "bonus_pebbles" => 5 }] })

      result = described_class.new(chore, user).call
      expect(result.completion.paid_pebbles).to eq(11) # 4 + 2 + 5
    end
  end

  describe "household-scoped streak bonuses + goal achievement" do
    let(:partner) { create(:user) }
    before { create(:chore_share, user: user, shared_with_user: partner) }

    it "applies a streak bonus created by a household partner" do
      shared_chore = create(:chore, created_by_user: user, reward_pebbles: 10)
      create(:chore_streak_bonus,
        user:   partner,
        chore:  nil,
        kind:   :daily_pebbles,
        config: { "levels" => [{ "threshold" => 0, "multiplier" => 2 }] })

      result = described_class.new(shared_chore, user).call
      expect(result.completion.paid_pebbles).to eq(20)
    end

    it "achieves a total_completions goal the moment the completion crosses the target" do
      chore = create(:chore, created_by_user: user, reward_pebbles: 1)
      goal = ChoreGoal.create!(
        user:         user,
        name:         "First completion",
        kind:         :total_completions,
        scope_mode:   :cumulative,
        target_value: 1,
        awarded_pebbles: 7,
      )
      result = described_class.new(chore, user).call
      expect(result.achieved_goals.map(&:id)).to include(goal.id)
      expect(goal.reload.achieved_at).to be_present
      expect(user.reload.chore_balance).to eq(1 + 7) # base reward + awarded_pebbles
    end

    it "does NOT re-fire achievement on subsequent completions once a goal is achieved" do
      chore = create(:chore, created_by_user: user, reward_pebbles: 1)
      goal = ChoreGoal.create!(
        user:         user,
        name:         "First completion",
        kind:         :total_completions,
        scope_mode:   :cumulative,
        target_value: 1,
      )
      described_class.new(chore, user).call
      original_at = goal.reload.achieved_at
      second = described_class.new(chore, user).call
      expect(second.achieved_goals).to be_empty
      expect(goal.reload.achieved_at).to eq(original_at)
    end
  end
end
