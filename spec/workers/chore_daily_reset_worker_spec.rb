require "rails_helper"

RSpec.describe ChoreDailyResetWorker do
  let(:user) { create(:user) }

  before do
    20.times { |i| create(:chore, created_by_user: user, reward_pebbles: (i % 4) + 1) } # 1..4
    8.times { |i| create(:chore, created_by_user: user, reward_pebbles: 5 + (i % 5)) }  # 5..9
    3.times { |i| create(:chore, created_by_user: user, reward_pebbles: 15 + i) }       # >10
  end

  it "creates 5 low + 2 medium hot picks for the day" do
    described_class.new.perform
    day = ChoreDay.current
    picks = ChoreHotPick.where(day_key: day).to_a

    low_picks = picks.select { |p| (1..4).cover?(p.chore.reward_pebbles) }
    medium_picks = picks.select { |p| (5..10).cover?(p.chore.reward_pebbles) }

    expect(low_picks.size).to eq(5)
    expect(medium_picks.size).to eq(2)
    # All picks default to 2x or 5x — never below
    expect(picks.map(&:multiplier).min).to be >= 2.0
  end

  it "is idempotent for the same day" do
    described_class.new.perform
    described_class.new.perform
    expect(ChoreHotPick.where(day_key: ChoreDay.current).count).to be_between(7, 8) # 5 low + 2 med (+ maybe 1 premium)
  end

  it "archives one-offs completed on the previous day" do
    today = ChoreDay.current
    oneoff = create(:chore, created_by_user: user, one_off: true, reward_pebbles: 3)
    untouched_oneoff = create(:chore, created_by_user: user, one_off: true, reward_pebbles: 3)
    create(:chore_completion, user: user, chore: oneoff, day_key: today - 1)

    described_class.new.perform

    expect(oneoff.reload.archived?).to eq(true)
    expect(untouched_oneoff.reload.archived?).to eq(false)
  end

  it "zeros stale streaks (last_completed_day older than yesterday)" do
    chore = create(:chore, created_by_user: user)
    stale = ChoreStreak.create!(user: user, chore: chore, current_streak: 4, longest_streak: 9, last_completed_day: 3.days.ago.to_date)
    fresh = ChoreStreak.create!(user: user, chore: create(:chore, created_by_user: user), current_streak: 4, longest_streak: 9, last_completed_day: ChoreDay.current)

    described_class.new.perform

    expect(stale.reload.current_streak).to eq(0)
    expect(stale.longest_streak).to eq(9) # preserved
    expect(fresh.reload.current_streak).to eq(4)
  end
end
