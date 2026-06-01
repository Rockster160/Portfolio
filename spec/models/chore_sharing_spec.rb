require "rails_helper"

RSpec.describe "Chore sharing modes" do
  let(:alice) { create(:user) }
  let(:bob)   { create(:user) }
  let(:carl)  { create(:user) }

  before { create(:chore_share, user: alice, shared_with_user: bob) }

  describe "broadcasts on persistence" do
    it "fans out a ChoreBroadcaster call when a chore is created via the model" do
      expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(alice, kind_of(Chore))
      Chore.create!(name: "Surprise", created_by_user: alice, reward_pebbles: 1)
    end

    it "fires the same broadcast on archival / destroy" do
      chore = create(:chore, created_by_user: alice, name: "X", reward_pebbles: 1)
      expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(alice, chore).twice
      chore.update!(archived_at: Time.current)
      chore.destroy!
    end
  end

  describe "accessible_chores filtering" do
    it "personal + household with no assignee are visible to everyone in the household" do
      personal  = create(:chore, created_by_user: alice, sharing_mode: :personal)
      household = create(:chore, created_by_user: alice, sharing_mode: :household)

      expect(alice.accessible_chores).to include(personal, household)
      expect(bob.accessible_chores).to include(personal, household)
      expect(carl.accessible_chores).to be_empty
    end

    it "personal + assigned hides the chore from non-assignees entirely" do
      to_alice = create(:chore, created_by_user: alice, sharing_mode: :personal, assigned_to_user: alice)
      to_bob   = create(:chore, created_by_user: alice, sharing_mode: :personal, assigned_to_user: bob)

      expect(alice.accessible_chores).to include(to_alice)
      expect(alice.accessible_chores).not_to include(to_bob)
      expect(bob.accessible_chores).to include(to_bob)
      expect(bob.accessible_chores).not_to include(to_alice)
    end

    it "household + assigned stays grid-visible to everyone in the household" do
      house_assigned = create(:chore,
        created_by_user: alice, sharing_mode: :household, assigned_to_user: bob)

      expect(alice.accessible_chores).to include(house_assigned)
      expect(bob.accessible_chores).to include(house_assigned)
    end

    it "assigned_to_user_id can be set on either sharing mode without a callback wiping it" do
      personal_assigned  = create(:chore, created_by_user: alice, sharing_mode: :personal,  assigned_to_user: alice)
      household_assigned = create(:chore, created_by_user: alice, sharing_mode: :household, assigned_to_user: bob)

      expect(personal_assigned.reload.assigned_to_user_id).to eq(alice.id)
      expect(household_assigned.reload.assigned_to_user_id).to eq(bob.id)
    end
  end

  describe "Today visibility (household + assigned)" do
    it "today_visible? is true only for the assignee" do
      chore = create(:chore,
        created_by_user: alice, sharing_mode: :household,
        assigned_to_user: bob, show_on_daily_view: :always)
      alice_view = ChoreSerializer.new(chore, viewer: alice).as_json
      bob_view   = ChoreSerializer.new(chore, viewer: bob).as_json
      expect(alice_view[:today_visible]).to be(false)
      expect(bob_view[:today_visible]).to be(true)
    end

    it "with no assignee, Today follows normal show_on_daily_view rules for everyone" do
      chore = create(:chore,
        created_by_user: alice, sharing_mode: :household, show_on_daily_view: :always)
      expect(ChoreSerializer.new(chore, viewer: alice).as_json[:today_visible]).to be(true)
      expect(ChoreSerializer.new(chore, viewer: bob).as_json[:today_visible]).to be(true)
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
