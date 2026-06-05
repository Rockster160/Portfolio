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

    expect(oneoff.reload.archived?).to be(true)
    expect(untouched_oneoff.reload.archived?).to be(false)
  end

  describe "hot eligibility — (overdue OR unscheduled) AND not on cooldown" do
    it "excludes a scheduled chore that is not yet due (future-only)" do
      Chore.delete_all
      today = ChoreDay.current
      # Scheduled to recur on a single far-future weekday only.
      far_future_wday = ((today + 5).wday)
      weekday_keys = %i[sun mon tue wed thu fri sat]
      future_only = create(
        :chore, created_by_user: user, reward_pebbles: 2,
        recurrence: { freq: :weekly, by_day: [weekday_keys[far_future_wday]] },
        starts_on: today + 5
      )

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: today).pluck(:chore_id)
      expect(picked_ids).not_to include(future_only.id)
    end

    it "includes a scheduled chore that is overdue (last scheduled day passed, no completion since)" do
      Chore.delete_all
      today = ChoreDay.current
      weekday_keys = %i[sun mon tue wed thu fri sat]
      # Weekly on yesterday's weekday → last scheduled day was yesterday,
      # no completion since → overdue.
      overdue = create(
        :chore, created_by_user: user, reward_pebbles: 2,
        recurrence: { freq: :weekly, by_day: [weekday_keys[(today - 1).wday]] },
        starts_on: today - 30
      )

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: today).pluck(:chore_id)
      expect(picked_ids).to include(overdue.id)
    end

    it "excludes a scheduled chore whose last scheduled day was already completed" do
      Chore.delete_all
      today = ChoreDay.current
      weekday_keys = %i[sun mon tue wed thu fri sat]
      satisfied = create(
        :chore, created_by_user: user, reward_pebbles: 2,
        recurrence: { freq: :weekly, by_day: [weekday_keys[(today - 1).wday]] },
        starts_on: today - 30
      )
      create(:chore_completion, user: user, chore: satisfied, day_key: today - 1)

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: today).pluck(:chore_id)
      expect(picked_ids).not_to include(satisfied.id)
    end

    it "includes an unscheduled chore" do
      Chore.delete_all
      unscheduled = create(:chore, created_by_user: user, reward_pebbles: 2)

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picked_ids).to include(unscheduled.id)
    end
  end

  describe "cooldown filtering" do
    it "excludes a fixed-cooldown chore whose threshold hasn't elapsed" do
      cooling = create(:chore, created_by_user: user, reward_pebbles: 2, threshold_seconds: 4.hours)
      create(:chore_completion, user: user, chore: cooling, completed_at: 30.minutes.ago, payout_skipped: false)

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picked_ids).not_to include(cooling.id)
    end

    it "includes a fixed-cooldown chore whose threshold has elapsed" do
      Chore.delete_all # remove the seeded pool so this is the only low-reward candidate
      ready = create(:chore, created_by_user: user, reward_pebbles: 2, threshold_seconds: 1.hour)
      create(:chore_completion, user: user, chore: ready, completed_at: 2.hours.ago, payout_skipped: false)

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picked_ids).to include(ready.id)
    end

    it "excludes a day-reset cooldown chore already completed today" do
      day_reset = create(
        :chore, created_by_user: user, reward_pebbles: 2,
        threshold_seconds: Chore::THRESHOLD_DAY_RESET
      )
      create(
        :chore_completion, user: user, chore: day_reset,
        day_key: ChoreDay.current, completed_at: 1.hour.ago, payout_skipped: false
      )

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picked_ids).not_to include(day_reset.id)
    end

    it "ignores skipped-payout completions when checking cooldown" do
      Chore.delete_all
      ready = create(:chore, created_by_user: user, reward_pebbles: 2, threshold_seconds: 4.hours)
      create(:chore_completion, user: user, chore: ready, completed_at: 30.minutes.ago, payout_skipped: true)

      described_class.new.perform

      picked_ids = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picked_ids).to include(ready.id)
    end
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

  describe "weighted_sample" do
    let(:worker) { described_class.new }

    it "picks every item with frequency proportional to its weight" do
      items = [:a, :b, :c]
      weights = { a: 1.0, b: 2.0, c: 7.0 } # totals to 10
      counts = Hash.new(0)
      trials = 5_000
      trials.times do
        picked = worker.send(:weighted_sample, items, 1) { |i| weights[i] }
        counts[picked.first] += 1
      end
      # Expected shares: a=10%, b=20%, c=70%. Allow ±3pp of slop.
      expect(counts[:a].fdiv(trials)).to be_within(0.03).of(0.10)
      expect(counts[:b].fdiv(trials)).to be_within(0.03).of(0.20)
      expect(counts[:c].fdiv(trials)).to be_within(0.03).of(0.70)
    end

    it "supports arbitrary floats and large integers" do
      items = [:x, :y]
      worker.send(:weighted_sample, items, 1) { |i| i == :x ? 0.0001 : 1_000_000 } # no raise
      worker.send(:weighted_sample, items, 2) { |i| i == :x ? 1.5 : 1.0 }          # no raise
      expect(worker.send(:weighted_sample, items, 1) { 0 }).to eq([]) # all-zero pool returns empty
    end
  end

  describe "hot_eligibility" do
    it ":never chores are excluded from hot-pick selection" do
      Chore.delete_all # reset baseline so this spec doesn't fight the outer 31-chore fixture
      11.times { create(:chore, created_by_user: user, reward_pebbles: 2, hot_eligibility: :when_available) }
      excluded = create(:chore, created_by_user: user, reward_pebbles: 2, hot_eligibility: :never)
      described_class.new.perform
      picks = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picks).not_to include(excluded.id)
    end

    it ":when_scheduled unscheduled chores are excluded from hot-pick selection" do
      Chore.delete_all
      # 5 always-eligible scheduled chores so low-band picks have plenty of room
      5.times {
        create(
          :chore, created_by_user: user, reward_pebbles: 2, hot_eligibility: :when_available,
          recurrence: { freq: "daily" }, starts_on: Date.current
        )
      }
      excluded = create(:chore, created_by_user: user, reward_pebbles: 2, hot_eligibility: :when_scheduled)
      described_class.new.perform
      picks = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picks).not_to include(excluded.id)
    end
  end
end
