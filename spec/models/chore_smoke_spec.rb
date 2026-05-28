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

  it "ChoreShare prevents self-share + duplicate pairs" do
    other = create(:user)
    create(:chore_share, user: user, shared_with_user: other)
    dup = ChoreShare.new(user: user, shared_with_user: other)
    expect(dup).not_to be_valid

    self_share = ChoreShare.new(user: user, shared_with_user: user)
    expect(self_share).not_to be_valid
  end

  it "accessible_chores includes own + shared-with-me" do
    owner = create(:user)
    member = create(:user)
    create(:chore_share, user: owner, shared_with_user: member)
    own = create(:chore, created_by_user: owner)
    expect(member.accessible_chores).to include(own)
  end
end
