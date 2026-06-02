require "rails_helper"

RSpec.describe "Chore models smoke", type: :model do
  let(:user) { create(:user) }

  it "loads all chore classes without error" do
    chore = create(:chore, created_by_user: user, name: "Brush Teeth", reward_pebbles: 1)
    expect(chore).to be_persisted
    expect(chore.reward_label).to eq("1p")
  end

  it "ChoreDay returns date in user tz using 4am cutoff" do
    travel_to Time.zone.local(2026, 5, 28, 3, 30, 0) do
      expect(ChoreDay.current).to eq(Date.new(2026, 5, 27))
    end
    travel_to Time.zone.local(2026, 5, 28, 5, 0, 0) do
      expect(ChoreDay.current).to eq(Date.new(2026, 5, 28))
    end
  end

  it "User#chore_balance sums completions minus withdrawals" do
    create(:chore_completion, user: user, paid_pebbles: 12)
    create(:chore_completion, user: user, paid_pebbles: 5)
    create(:chore_withdrawal, user: user, amount_pebbles: 7)
    expect(user.chore_balance).to eq(10)
  end

  it "Household membership is unique per user" do
    household_a = create(:chore_household, owner_user: user)
    other = create(:user)
    create(:chore_household_membership, chore_household: household_a, user: other, role: :member)

    household_b = create(:chore_household, owner_user: create(:user))
    dup = ChoreHouseholdMembership.new(chore_household: household_b, user: other, role: :member)
    expect(dup).not_to be_valid
  end

  it "Owner gets an implicit manager membership" do
    household = create(:chore_household, owner_user: user)
    membership = household.memberships.find_by(user_id: user.id)
    expect(membership).to be_present
    expect(membership.role.to_sym).to eq(:manager)
  end

  it "accessible_chores includes all chores in the household" do
    owner = create(:user)
    member = create(:user)
    household = create(:chore_household, owner_user: owner)
    create(:chore_household_membership, chore_household: household, user: member, role: :member)
    chore = create(:chore, created_by_user: owner, chore_household: household)
    expect(member.reload.accessible_chores).to include(chore)
  end
end
