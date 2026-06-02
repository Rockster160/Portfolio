require "rails_helper"

RSpec.describe "Chore household visibility + cooldown" do
  let(:alice) { create(:user) }
  let(:bob)   { create(:user) }
  let(:carl)  { create(:user) }
  let!(:household) { create(:chore_household, owner_user: alice) }

  before do
    create(:chore_household_membership, chore_household: household, user: bob, role: :manager)
    [alice, bob].each(&:reload)
  end

  describe "broadcasts on persistence" do
    it "fans out a ChoreBroadcaster call when a chore is created via the model" do
      expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(alice, kind_of(Chore))
      Chore.create!(name: "Surprise", created_by_user: alice, chore_household: household, reward_pebbles: 1)
    end

    it "fires the same broadcast on archival / destroy" do
      chore = create(:chore, created_by_user: alice, chore_household: household, name: "X", reward_pebbles: 1)
      expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(alice, chore).twice
      chore.update!(archived_at: Time.current)
      chore.destroy!
    end
  end

  describe "accessible_chores filtering" do
    it "personal + household with no assignee are visible to everyone in the household" do
      personal  = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :personal)
      household_chore = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :household)

      expect(alice.accessible_chores).to include(personal, household_chore)
      expect(bob.accessible_chores).to include(personal, household_chore)
      expect(carl.accessible_chores).to be_empty
    end

    it "personal + assigned hides the chore from non-assignees entirely" do
      to_alice = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :personal, assigned_to_user: alice)
      to_bob   = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :personal, assigned_to_user: bob)

      expect(alice.accessible_chores).to include(to_alice)
      expect(alice.accessible_chores).not_to include(to_bob)
      expect(bob.accessible_chores).to include(to_bob)
      expect(bob.accessible_chores).not_to include(to_alice)
    end

    it "household + assigned stays grid-visible to everyone in the household" do
      house_assigned = create(:chore,
        created_by_user: alice, chore_household: household,
        sharing_mode: :household, assigned_to_user: bob)

      expect(alice.accessible_chores).to include(house_assigned)
      expect(bob.accessible_chores).to include(house_assigned)
    end

    it "users without a household see nothing" do
      create(:chore, created_by_user: alice, chore_household: household)
      expect(carl.accessible_chores).to be_empty
      expect(carl.chore_household_user_ids).to eq([carl.id])
    end
  end

  describe "Today visibility (household + assigned)" do
    it "today_visible? is true only for the assignee" do
      chore = create(:chore,
        created_by_user: alice, chore_household: household,
        sharing_mode: :household,
        assigned_to_user: bob, show_on_daily_view: :always)
      alice_view = ChoreSerializer.new(chore, viewer: alice).as_json
      bob_view   = ChoreSerializer.new(chore, viewer: bob).as_json
      expect(alice_view[:today_visible]).to be(false)
      expect(bob_view[:today_visible]).to be(true)
    end

    it "with no assignee, Today follows normal show_on_daily_view rules for everyone" do
      chore = create(:chore,
        created_by_user: alice, chore_household: household,
        sharing_mode: :household, show_on_daily_view: :always)
      expect(ChoreSerializer.new(chore, viewer: alice).as_json[:today_visible]).to be(true)
      expect(ChoreSerializer.new(chore, viewer: bob).as_json[:today_visible]).to be(true)
    end
  end

  describe "cooldown — household shares the timer across the group" do
    let(:chore) {
      create(:chore, created_by_user: alice, chore_household: household,
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
      create(:chore, created_by_user: alice, chore_household: household,
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

  describe "ChoreHousehold roles" do
    let(:member) { create(:user) }
    before { create(:chore_household_membership, chore_household: household, user: member, role: :member) }

    it "owner is implicitly a manager" do
      expect(household.manager?(alice)).to be(true)
    end

    it "managers can manage chores; members cannot" do
      expect(bob.reload.can_manage_chores?).to be(true)
      expect(member.reload.can_manage_chores?).to be(false)
    end

    it "transfers are restricted to household peers" do
      outsider = create(:user)
      create(:chore_completion, user: bob, paid_pebbles: 10, base_pebbles: 10, payout_skipped: false)
      ok = ChoreTransfer.new(from_user: bob, to_user: alice, amount_pebbles: 1)
      bad = ChoreTransfer.new(from_user: bob, to_user: outsider, amount_pebbles: 1)
      expect(ok).to be_valid
      expect(bad).not_to be_valid
      expect(bad.errors[:to_user_id]).to include("must be in your chore household")
    end
  end
end
