require "rails_helper"

RSpec.describe ChoreDailyResetWorker do
  let(:user) { create(:user) }

  # A household with enough chores in each reward band to sample from; only the
  # examples about the SHAPE of a day's picks need it.
  def seed_reward_pool
    20.times { |i| create(:chore, created_by_user: user, reward_pebbles: (i % 4) + 1) } # 1..4
    8.times { |i| create(:chore, created_by_user: user, reward_pebbles: 5 + (i % 5)) }  # 5..9
    3.times { |i| create(:chore, created_by_user: user, reward_pebbles: 15 + i) }       # >10
  end

  it "creates 5 low + 2 medium hot picks for the day" do
    seed_reward_pool
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
    seed_reward_pool
    described_class.new.perform
    described_class.new.perform
    expect(ChoreHotPick.where(day_key: ChoreDay.current).count).to be_between(7, 8) # 5 low + 2 med (+ maybe 1 premium)
  end

  # A single task carrying a recurrence stays on the list until it's completed
  # once; completion then finishes it like any one-off.
  it "archives one-offs (recurring or not) completed on the previous day" do
    today = ChoreDay.current
    oneoff = create(:chore, created_by_user: user, one_off: true, reward_pebbles: 3)
    untouched_oneoff = create(:chore, created_by_user: user, one_off: true, reward_pebbles: 3)
    scheduled = create(
      :chore, created_by_user: user, one_off: true, reward_pebbles: 3,
      recurrence: { freq: :daily }
    )
    create(:chore_completion, user: user, chore: oneoff, day_key: today - 1)
    create(:chore_completion, user: user, chore: scheduled, day_key: today - 1)

    described_class.new.perform

    expect(oneoff.reload.archived?).to be(true)
    expect(scheduled.reload.archived?).to be(true)
    expect(untouched_oneoff.reload.archived?).to be(false)
  end

  describe "#clear_completed_marked_due!" do
    it "clears a mark only when a completion (own or a sub-chore's) postdates it" do
      cleared = create(:chore, created_by_user: user, marked_due_at: 6.hours.ago)
      create(:chore_completion, user: user, chore: cleared, completed_at: 1.hour.ago)

      stale_mark_at = 1.hour.ago
      stale = create(:chore, created_by_user: user, marked_due_at: stale_mark_at)
      create(:chore_completion, user: user, chore: stale, completed_at: 6.hours.ago)

      untouched_mark_at = 6.hours.ago
      untouched = create(:chore, created_by_user: user, marked_due_at: untouched_mark_at)

      parent = create(:chore, created_by_user: user, marked_due_at: 6.hours.ago, recurrence: { freq: :never })
      parents_sub = create(:chore, created_by_user: user, parent_chore: parent, one_off: true)
      create(:chore_completion, user: user, chore: parents_sub, completed_at: 1.hour.ago)

      other_parent = create(:chore, created_by_user: user, recurrence: { freq: :never })
      marked_sub = create(
        :chore, created_by_user: user, parent_chore: other_parent, one_off: true,
        marked_due_at: 6.hours.ago
      )
      create(:chore_completion, user: user, chore: marked_sub, completed_at: 1.hour.ago)

      described_class.new.perform

      expect(cleared.reload.marked_due_at).to be_nil
      expect(stale.reload.marked_due_at).to be_within(1.second).of(stale_mark_at)
      expect(untouched.reload.marked_due_at).to be_within(1.second).of(untouched_mark_at)
      expect(parent.reload.marked_due_at).to be_nil
      expect(marked_sub.reload.marked_due_at).to be_nil
    end
  end

  # Hot eligibility is (overdue OR unscheduled) AND not on cooldown. Every
  # candidate here is in the low band, and there are fewer eligible ones than
  # the band takes, so each eligible chore is picked.
  it "picks only chores that are overdue or unscheduled, and off cooldown" do
    today = ChoreDay.current
    weekday_keys = %i[sun mon tue wed thu fri sat]
    weekly_yesterday = { freq: :weekly, by_day: [weekday_keys[(today - 1).wday]] }
    low = { created_by_user: user, reward_pebbles: 2 }

    future_only = create(
      :chore, **low,
      recurrence: { freq: :weekly, by_day: [weekday_keys[(today + 5).wday]] }, starts_on: today + 5
    )
    overdue = create(:chore, **low, recurrence: weekly_yesterday, starts_on: today - 30)
    satisfied = create(:chore, **low, recurrence: weekly_yesterday, starts_on: today - 30)
    create(:chore_completion, user: user, chore: satisfied, day_key: today - 1)
    unscheduled = create(:chore, **low)

    cooling = create(:chore, **low, threshold_seconds: 4.hours)
    create(:chore_completion, user: user, chore: cooling, completed_at: 30.minutes.ago, payout_skipped: false)
    day_reset = create(:chore, **low, threshold_seconds: Chore::THRESHOLD_DAY_RESET)
    create(
      :chore_completion, user: user, chore: day_reset,
      day_key: today, completed_at: 1.hour.ago, payout_skipped: false
    )
    ready = create(:chore, **low, threshold_seconds: 1.hour)
    create(:chore_completion, user: user, chore: ready, completed_at: 2.hours.ago, payout_skipped: false)
    # A skipped-payout completion doesn't start a cooldown.
    skipped_payout = create(:chore, **low, threshold_seconds: 4.hours)
    create(:chore_completion, user: user, chore: skipped_payout, completed_at: 30.minutes.ago, payout_skipped: true)

    described_class.new.perform

    picked_ids = ChoreHotPick.where(day_key: today).pluck(:chore_id)
    expect(picked_ids).to include(overdue.id, unscheduled.id, ready.id, skipped_payout.id)
    expect(picked_ids).not_to include(future_only.id, satisfied.id, cooling.id, day_reset.id)
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

  describe "weight_for / schedule_weight_sets" do
    let(:worker) { described_class.new }
    let(:day)    { Date.new(2026, 6, 8) } # Monday

    def make(opts = {})
      defaults = {
        created_by_user: user,
        reward_pebbles: 2,
        hot_eligibility: :when_available,
        show_on_today_view: :when_scheduled,
      }
      create(:chore, defaults.merge(opts))
    end

    it "recurring-daily chores stay at baseline (not boosted as 'today')" do
      daily = make(recurrence: { freq: "daily" }, starts_on: day - 30)
      today_ids, overdue_ids = worker.send(:schedule_weight_sets, [daily], day)
      expect(today_ids).not_to include(daily.id)
      expect(overdue_ids).not_to include(daily.id)
      expect(worker.send(:weight_for, daily, today_ids, overdue_ids)).to eq(described_class::BASELINE_WEIGHT)
    end

    it "non-daily chores matching today get TODAY_DUE_WEIGHT" do
      weekly_mon = make(recurrence: { freq: "weekly", by_day: ["mon"] }, starts_on: day - 30)
      today_ids, overdue_ids = worker.send(:schedule_weight_sets, [weekly_mon], day)
      expect(today_ids).to include(weekly_mon.id)
      expect(worker.send(:weight_for, weekly_mon, today_ids, overdue_ids)).to eq(described_class::TODAY_DUE_WEIGHT)
    end

    it "chores whose last scheduled day is in the past with no completion since get OVERDUE_WEIGHT" do
      # Weekly Sunday — day is Monday, so the last scheduled day was
      # yesterday (Sunday) and (no completions) → overdue.
      weekly_sun = make(recurrence: { freq: "weekly", by_day: ["sun"] }, starts_on: day - 30)
      today_ids, overdue_ids = worker.send(:schedule_weight_sets, [weekly_sun], day)
      expect(today_ids).not_to include(weekly_sun.id)
      expect(overdue_ids).to include(weekly_sun.id)
      expect(worker.send(:weight_for, weekly_sun, today_ids, overdue_ids)).to eq(described_class::OVERDUE_WEIGHT)
    end

    it "an overdue-by-pattern chore completed since its last scheduled day is NOT overdue" do
      weekly_sun = make(recurrence: { freq: "weekly", by_day: ["sun"] }, starts_on: day - 30)
      create(:chore_completion, chore: weekly_sun, user: user, paid_pebbles: 1,
        completed_at: (day - 1).to_time, day_key: day - 1)
      _, overdue_ids = worker.send(:schedule_weight_sets, [weekly_sun], day)
      expect(overdue_ids).not_to include(weekly_sun.id)
    end
  end

  describe "hot_eligibility" do
    it ":never chores are excluded from hot-pick selection" do
      11.times { create(:chore, created_by_user: user, reward_pebbles: 2, hot_eligibility: :when_available) }
      excluded = create(:chore, created_by_user: user, reward_pebbles: 2, hot_eligibility: :never)
      described_class.new.perform
      picks = ChoreHotPick.where(day_key: ChoreDay.current).pluck(:chore_id)
      expect(picks).not_to include(excluded.id)
    end

    it ":when_scheduled unscheduled chores are excluded from hot-pick selection" do
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

  describe "priority weighting" do
    let(:worker) { described_class.new }
    let(:day) { ChoreDay.current }

    it "scales the schedule weight by the priority multiplier" do
      baseline = create(:chore, created_by_user: user, priority: :normal)
      critical = create(:chore, created_by_user: user, priority: :critical)
      low      = create(:chore, created_by_user: user, priority: :low)
      empty    = Set.new

      expect(worker.send(:weight_for, baseline, empty, empty)).to eq(1.0)
      expect(worker.send(:weight_for, critical, empty, empty)).to eq(2.0)
      expect(worker.send(:weight_for, low, empty, empty)).to eq(0.5)
      expect(worker.send(:weight_for, create(:chore, created_by_user: user, priority: :none), empty, empty)).to eq(0.0)
    end

    it "compounds with the due-today schedule weight rather than replacing it" do
      chore = create(:chore, created_by_user: user, priority: :high)

      expect(worker.send(:weight_for, chore, Set.new([chore.id]), Set.new)).to eq(3.0)   # 2.0 today × 1.5
      expect(worker.send(:weight_for, chore, Set.new, Set.new([chore.id]))).to eq(2.25)  # 1.5 overdue × 1.5
    end

    it "never picks a :none chore even when it's the only candidate in its band" do
      skipped = create(:chore, created_by_user: user, reward_pebbles: 2, priority: :none)
      premium = create(:chore, created_by_user: user, reward_pebbles: 20, priority: :none)

      described_class.new.perform

      picks = ChoreHotPick.where(day_key: day).pluck(:chore_id)
      expect(picks).to be_empty
      expect(picks).not_to include(skipped.id, premium.id)
    end

    it "still fills the low band from the non-:none candidates" do
      eligible = 5.times.map { create(:chore, created_by_user: user, reward_pebbles: 2, priority: :low) }
      skipped  = create(:chore, created_by_user: user, reward_pebbles: 2, priority: :none)

      described_class.new.perform

      picks = ChoreHotPick.where(day_key: day).pluck(:chore_id)
      expect(picks).to match_array(eligible.map(&:id))
      expect(picks).not_to include(skipped.id)
    end
  end
end
