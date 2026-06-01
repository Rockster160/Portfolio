require "rails_helper"

RSpec.describe ChoreGoal do
  let(:user) { create(:user) }

  describe "kinds — current_value, reached?, refresh!" do
    let(:chore) { create(:chore, created_by_user: user, reward_pebbles: 5) }

    describe ":pebbles" do
      it "tracking_mode=earned counts lifetime paid_pebbles (ignores withdrawals)" do
        goal = ChoreGoal.create!(user: user, name: "G", kind: :pebbles,
                                 scope_mode: :cumulative, tracking_mode: :earned, target_value: 10)
        create(:chore_completion, user: user, chore: chore, paid_pebbles: 7)
        create(:chore_completion, user: user, chore: chore, paid_pebbles: 5)
        create(:chore_withdrawal, user: user, amount_pebbles: 8)

        expect(goal.current_value).to eq(12)
        expect(goal.reached?).to be(true)
      end

      it "tracking_mode=saved subtracts withdrawals via user.chore_balance" do
        goal = ChoreGoal.create!(user: user, name: "G", kind: :pebbles,
                                 scope_mode: :cumulative, tracking_mode: :saved, target_value: 10)
        create(:chore_completion, user: user, chore: chore, paid_pebbles: 7)
        create(:chore_completion, user: user, chore: chore, paid_pebbles: 5)
        create(:chore_withdrawal, user: user, amount_pebbles: 8)

        expect(goal.current_value).to eq(4) # 12 earned − 8 withdrawn
        expect(goal.reached?).to be(false)
      end

      it "scope_mode=relative subtracts the baseline snapshotted at creation" do
        create(:chore_completion, user: user, chore: chore, paid_pebbles: 30)
        goal = ChoreGoal.create!(user: user, name: "G", kind: :pebbles,
                                 scope_mode: :relative, tracking_mode: :earned, target_value: 10)
        expect(goal.baseline_value).to eq(30)
        expect(goal.current_value).to eq(0)

        create(:chore_completion, user: user, chore: chore, paid_pebbles: 12)
        expect(goal.reload.current_value).to eq(12)
        expect(goal.reached?).to be(true)
      end
    end

    describe ":chore_completions" do
      it "counts only completions of its configured chore" do
        other = create(:chore, created_by_user: user, name: "Other")
        goal = ChoreGoal.create!(user: user, name: "Drink 3", kind: :chore_completions,
                                 scope_mode: :cumulative, target_value: 3, chore: chore)
        create(:chore_completion, user: user, chore: chore)
        create(:chore_completion, user: user, chore: chore)
        create(:chore_completion, user: user, chore: other) # ignored

        expect(goal.current_value).to eq(2)
        expect(goal.reached?).to be(false)
      end

      it "relative snapshots the baseline so an existing count doesn't pre-fill progress" do
        create(:chore_completion, user: user, chore: chore)
        create(:chore_completion, user: user, chore: chore)
        goal = ChoreGoal.create!(user: user, name: "Drink 100", kind: :chore_completions,
                                 scope_mode: :relative, target_value: 100, chore: chore)
        expect(goal.baseline_value).to eq(2)
        expect(goal.current_value).to eq(0) # was the 2/100 bug
      end
    end

    describe ":chore_streak" do
      it "cumulative uses max(current_streak, longest_streak)" do
        ChoreStreak.create!(user: user, chore: chore, current_streak: 3, longest_streak: 9)
        goal = ChoreGoal.create!(user: user, name: "Streak", kind: :chore_streak,
                                 scope_mode: :cumulative, target_value: 5, chore: chore)
        expect(goal.current_value).to eq(9)
        expect(goal.reached?).to be(true)
      end

      it "relative ignores streaks that started before the goal was created" do
        # Set today = current_streak's last day; streak began 4 days ago.
        today = ChoreDay.current(user)
        ChoreStreak.create!(user: user, chore: chore, current_streak: 5,
                            longest_streak: 5, last_completed_day: today)
        goal = ChoreGoal.create!(user: user, name: "Streak", kind: :chore_streak,
                                 scope_mode: :relative, target_value: 3, chore: chore,
                                 created_at: Time.current)
        # streak_start = today - 4 < created_at → 0
        expect(goal.current_value).to eq(0)
      end
    end
  end

  describe "validation" do
    it "requires a chore_id config key for chore-specific kinds" do
      goal = ChoreGoal.new(user: user, name: "Bad", kind: :chore_streak, target_value: 5)
      expect(goal).not_to be_valid
      expect(goal.errors[:base].join).to match(/chore/i)
    end

    it "requires a positive target_value" do
      goal = ChoreGoal.new(user: user, name: "Bad", kind: :pebbles, target_value: 0)
      expect(goal).not_to be_valid
    end
  end

  describe "refresh! semantics" do
    let(:chore) { create(:chore, created_by_user: user, reward_pebbles: 5) }

    it "is idempotent — re-running on an achieved goal is a no-op" do
      goal = ChoreGoal.create!(user: user, name: "Easy", kind: :pebbles,
                               scope_mode: :cumulative, target_value: 1)
      create(:chore_completion, user: user, chore: chore, paid_pebbles: 5)
      expect(goal.refresh!).to be(true)
      first_at = goal.reload.achieved_at
      expect(goal.refresh!).to be(false)
      expect(goal.reload.achieved_at).to eq(first_at)
    end

    it "is a no-op when the goal hasn't been reached" do
      goal = ChoreGoal.create!(user: user, name: "Hard", kind: :pebbles,
                               scope_mode: :cumulative, target_value: 1000)
      expect(goal.refresh!).to be(false)
      expect(goal.reload.achieved_at).to be_nil
    end
  end

  describe "default scope_mode" do
    it "defaults to :relative (so existing progress doesn't pre-fill a new goal)" do
      goal = ChoreGoal.new(user: user, name: "G", kind: :pebbles, target_value: 10)
      expect(goal.scope_mode).to eq("relative")
    end
  end
end
