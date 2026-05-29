require "rails_helper"

RSpec.describe ChoreTransfer, type: :model do
  let(:sender)    { create(:user) }
  let(:recipient) { create(:user) }
  let!(:share)    { create(:chore_share, user: sender, shared_with_user: recipient) }

  def fund!(user, amount)
    chore = create(:chore, created_by_user: user, reward_pebbles: amount)
    create(:chore_completion, chore: chore, user: user,
           paid_pebbles: amount, base_pebbles: amount, payout_skipped: false,
           day_key: ChoreDay.current(user) - 1)
  end

  it "moves pebbles from sender to recipient" do
    fund!(sender, 50)
    expect(sender.chore_balance).to eq(50)
    expect(recipient.chore_balance).to eq(0)

    ChoreTransfer.create!(from_user: sender, to_user: recipient, amount_pebbles: 30, note: "snacks")

    expect(sender.reload.chore_balance).to eq(20)
    expect(recipient.reload.chore_balance).to eq(30)
  end

  it "rejects a transfer over the sender's available balance" do
    fund!(sender, 10)
    t = ChoreTransfer.new(from_user: sender, to_user: recipient, amount_pebbles: 25)
    expect(t).not_to be_valid
    expect(t.errors[:amount_pebbles]).to include(/exceeds your available balance/)
  end

  it "rejects a transfer to a non-household user" do
    fund!(sender, 50)
    stranger = create(:user)
    t = ChoreTransfer.new(from_user: sender, to_user: stranger, amount_pebbles: 5)
    expect(t).not_to be_valid
    expect(t.errors[:to_user_id]).to include(/chore household/)
  end

  it "rejects a transfer to yourself" do
    fund!(sender, 50)
    t = ChoreTransfer.new(from_user: sender, to_user: sender, amount_pebbles: 5)
    expect(t).not_to be_valid
    expect(t.errors[:to_user_id]).to include(/yourself/)
  end

  it "rejects zero / negative amounts" do
    fund!(sender, 50)
    expect(ChoreTransfer.new(from_user: sender, to_user: recipient, amount_pebbles: 0)).not_to be_valid
    expect(ChoreTransfer.new(from_user: sender, to_user: recipient, amount_pebbles: -1)).not_to be_valid
  end
end
