require "rails_helper"

RSpec.describe "Chore sharing modes" do
  let(:alice) { create(:user) }
  let(:bob)   { create(:user) }
  let(:carl)  { create(:user) }

  before { create(:chore_share, user: alice, shared_with_user: bob) }

  describe "accessible_chores filtering" do
    it "personal + household show to both alice and bob; assigned only to assignee" do
      personal   = create(:chore, created_by_user: alice, sharing_mode: :personal)
      household  = create(:chore, created_by_user: alice, sharing_mode: :household)
      to_alice   = create(:chore, created_by_user: alice, sharing_mode: :assigned, assigned_to_user: alice)
      to_bob     = create(:chore, created_by_user: alice, sharing_mode: :assigned, assigned_to_user: bob)

      expect(alice.accessible_chores).to include(personal, household, to_alice)
      expect(alice.accessible_chores).not_to include(to_bob)

      expect(bob.accessible_chores).to include(personal, household, to_bob)
      expect(bob.accessible_chores).not_to include(to_alice)

      # carl is not in the share group at all
      expect(carl.accessible_chores).to be_empty
    end

    it ":assigned mode requires assigned_to_user_id" do
      c = build(:chore, created_by_user: alice, sharing_mode: :assigned, assigned_to_user_id: nil)
      expect(c).not_to be_valid
      expect(c.errors[:assigned_to_user_id]).to be_present
    end

    it "switching away from :assigned clears the assignee" do
      c = create(:chore, created_by_user: alice, sharing_mode: :assigned, assigned_to_user: bob)
      c.update!(sharing_mode: :personal)
      expect(c.reload.assigned_to_user_id).to be_nil
    end
  end

  describe "cooldown — household shares the timer across the group" do
    let(:chore) {
      create(:chore, created_by_user: alice,
        sharing_mode: :household, reward_pebbles: 5, threshold_seconds: 6 * 3600)
    }

    it "alice completes → bob taps 1h later → bob's payout is skipped" do
      base = Time.current
      travel_to(base) { ChoreCompleter.new(chore, alice).call }
      travel_to(base + 1.hour) {
        result = ChoreCompleter.new(chore, bob).call
        expect(result).to be_skipped
        expect(result.completion.paid_pebbles).to eq(0)
      }
      # Alice was paid, bob wasn't:
      expect(alice.reload.chore_balance).to eq(5)
      expect(bob.reload.chore_balance).to eq(0)
    end

    it "after the window, the next tapper IS paid" do
      base = Time.current
      travel_to(base) { ChoreCompleter.new(chore, alice).call }
      travel_to(base + 7.hours) {
        result = ChoreCompleter.new(chore, bob).call
        expect(result).not_to be_skipped
        expect(result.completion.paid_pebbles).to eq(5)
      }
    end
  end

  describe "cooldown — personal is independent per user" do
    let(:chore) {
      create(:chore, created_by_user: alice,
        sharing_mode: :personal, reward_pebbles: 5, threshold_seconds: 6 * 3600)
    }

    it "both users get paid even when they tap minutes apart" do
      base = Time.current
      travel_to(base)            { ChoreCompleter.new(chore, alice).call }
      travel_to(base + 5.minutes) { ChoreCompleter.new(chore, bob).call }
      expect(alice.reload.chore_balance).to eq(5)
      expect(bob.reload.chore_balance).to eq(5)
    end
  end

  describe "symmetric household — one ChoreShare row covers both directions" do
    it "chores bob creates are visible to alice via the same single share row" do
      bob_chore = create(:chore, created_by_user: bob, sharing_mode: :personal)
      expect(alice.accessible_chores).to include(bob_chore)
      expect(bob.accessible_chores).to include(bob_chore)
      # carl has no share row — still invisible
      expect(carl.accessible_chores).not_to include(bob_chore)
    end

    it "household cooldown applies regardless of which side created the chore" do
      bob_chore = create(:chore, created_by_user: bob,
        sharing_mode: :household, reward_pebbles: 5, threshold_seconds: 6 * 3600)
      base = Time.current
      travel_to(base) { ChoreCompleter.new(bob_chore, alice).call }
      travel_to(base + 1.hour) {
        result = ChoreCompleter.new(bob_chore, bob).call
        expect(result).to be_skipped
      }
    end

    it "Chore.household_user_ids_for is symmetric" do
      expect(Chore.household_user_ids_for(alice.id)).to contain_exactly(alice.id, bob.id)
      expect(Chore.household_user_ids_for(bob.id)).to contain_exactly(alice.id, bob.id)
      expect(Chore.household_user_ids_for(carl.id)).to contain_exactly(carl.id)
    end

    it "is transitive — adding carl via bob folds carl into the household" do
      create(:chore_share, user: bob, shared_with_user: carl)
      [alice, bob, carl].each do |u|
        expect(Chore.household_user_ids_for(u.id)).to contain_exactly(alice.id, bob.id, carl.id)
      end
      carl_chore = create(:chore, created_by_user: carl, sharing_mode: :personal)
      expect(alice.accessible_chores).to include(carl_chore)
    end
  end
end
