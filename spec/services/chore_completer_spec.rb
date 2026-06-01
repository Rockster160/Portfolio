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

  it "evaluates achievements and awards bonus pebbles" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 1)
    ach = create(:chore_achievement, kind: :total_completions, config: { "count" => 1 }, reward_pebbles: 20)
    result = described_class.new(chore, user).call
    expect(result.awarded.size).to eq(1)
    expect(result.awarded.first.chore_achievement_id).to eq(ach.id)
    expect(user.chore_balance).to eq(1 + 20)
  end

  it "applies daily_pebble_threshold multiplier once threshold passed" do
    chore = create(:chore, created_by_user: user, reward_pebbles: 10)
    create(:chore_multiplier,
      user:   user,
      chore:  chore,
      kind:   :daily_pebble_threshold,
      config: { "levels" => [{ "threshold" => 5, "multiplier" => 1.5 }] })
    # First call earns 10 — but the multiplier kicks in for "current value",
    # which is computed BEFORE this completion lands, so first call pays
    # straight 10. Second call: prior day total now 10 ≥ 5, so 1.5x → 15.
    first = described_class.new(chore, user).call
    second = described_class.new(chore, user).call
    expect(first.completion.paid_pebbles).to eq(10)
    expect(second.completion.paid_pebbles).to eq(15)
  end

  describe "per-chore multiplier scoping" do
    let(:acnh)  { create(:chore, created_by_user: user, name: "ACNH Chores", reward_pebbles: 1) }
    let(:other) { create(:chore, created_by_user: user, name: "Vitamins",    reward_pebbles: 1) }
    before do
      create(:chore_multiplier,
        user:   user,
        chore:  acnh,
        kind:   :daily_streak,
        config: { "levels" => [
          { "threshold" => 1, "multiplier" => 1 },
          { "threshold" => 2, "multiplier" => 2 },
          { "threshold" => 3, "multiplier" => 3 },
          { "threshold" => 4, "multiplier" => 4 },
          { "threshold" => 5, "multiplier" => 5 },
        ] })
    end

    it "applies the multiplier when completing its chore" do
      result = described_class.new(acnh, user).call
      # Fresh streak → streak_count 1 → multiplier level threshold:1 → 1x → 1 pebble.
      expect(result.completion.paid_pebbles).to eq(1)
    end

    it "does NOT apply the multiplier when completing a different chore" do
      result = described_class.new(other, user).call
      expect(result.completion.streak_multiplier).to eq(1.0)
      expect(result.completion.paid_pebbles).to eq(1)
    end

    it "caps at 5x once the streak hits 5+ consecutive days" do
      # Seed prior days to make today the 5th in a row.
      day = ChoreDay.current(user)
      ChoreStreak.create!(user: user, chore: acnh, current_streak: 4, last_completed_day: day - 1)
      result = described_class.new(acnh, user).call
      # streak after this completion = 5 → multiplier 5x → 1 × 5 = 5 pebbles
      expect(result.completion.paid_pebbles).to eq(5)
    end

    it "still caps at 5x even at streak 10 (no level above threshold:5)" do
      day = ChoreDay.current(user)
      ChoreStreak.create!(user: user, chore: acnh, current_streak: 9, last_completed_day: day - 1)
      result = described_class.new(acnh, user).call
      expect(result.completion.paid_pebbles).to eq(5)
    end
  end

  describe "household-scoped multipliers + achievements" do
    let(:partner) { create(:user) }
    before { create(:chore_share, user: user, shared_with_user: partner) }

    it "applies a multiplier created by a household partner" do
      shared_chore = create(:chore, created_by_user: user, reward_pebbles: 10)
      create(:chore_multiplier,
        user:   partner,
        chore:  shared_chore,
        kind:   :daily_pebble_threshold,
        config: { "levels" => [{ "threshold" => 0, "multiplier" => 2 }] })

      result = described_class.new(shared_chore, user).call
      expect(result.completion.paid_pebbles).to eq(20)
    end

    it "awards a household-scoped achievement to whichever member triggers it" do
      shared_chore = create(:chore, created_by_user: user, reward_pebbles: 1)
      ach = create(:chore_achievement,
        created_by_user: partner,
        kind: :total_completions, config: { "count" => 1 }, reward_pebbles: 7)
      result = described_class.new(shared_chore, user).call
      expect(result.awarded.map(&:chore_achievement_id)).to include(ach.id)
      expect(UserChoreAchievement.where(user_id: user.id, chore_achievement_id: ach.id)).to exist
    end

    it "hides an achievement whose creator is outside the household" do
      outsider = create(:user)
      hidden = create(:chore_achievement,
        created_by_user: outsider,
        kind: :total_completions, config: { "count" => 1 }, reward_pebbles: 7)
      shared_chore = create(:chore, created_by_user: user, reward_pebbles: 1)
      result = described_class.new(shared_chore, user).call
      expect(result.awarded.map(&:chore_achievement_id)).not_to include(hidden.id)
    end
  end
end
