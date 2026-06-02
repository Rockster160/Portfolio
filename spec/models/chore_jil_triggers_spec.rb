require "rails_helper"

RSpec.describe "Chore + ChoreCompletion Jil triggers", type: :model do
  let(:user) { create(:user) }

  it "creating a chore fires `chore` trigger with action: :created" do
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :created && attrs[:name] == "Vacuum" }
    )
    create(:chore, created_by_user: user, name: "Vacuum")
  end

  it "updating a chore fires action: :updated" do
    chore = create(:chore, created_by_user: user, name: "V")
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :updated }
    )
    chore.update!(name: "Vacuum")
  end

  it "archiving a chore (archived_at flip) fires action: :archived" do
    chore = create(:chore, created_by_user: user, name: "V")
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :archived }
    )
    chore.update!(archived_at: Time.current)
  end

  it "destroying a chore fires action: :destroyed" do
    chore = create(:chore, created_by_user: user, name: "V")
    expect(::Jil).to receive(:trigger).with(
      user, :chore, satisfy { |attrs| attrs[:action] == :destroyed }
    )
    chore.destroy!
  end

  it "creating a completion fires `chore_completion` action: :completed" do
    chore = create(:chore, created_by_user: user, name: "Walk", reward_pebbles: 4)
    expect(::Jil).to receive(:trigger).with(
      user, :chore_completion,
      satisfy { |a| a[:action] == :completed && a[:chore_name] == "Walk" && a[:paid_pebbles] == 4 }
    )
    ChoreCompleter.new(chore, user).call
  end

  it "destroying a completion fires `chore_completion` action: :uncompleted" do
    chore = create(:chore, created_by_user: user, name: "Walk")
    completion = ChoreCompleter.new(chore, user).call.completion
    expect(::Jil).to receive(:trigger).with(
      user, :chore_completion,
      satisfy { |a| a[:action] == :uncompleted && a[:chore_name] == "Walk" }
    )
    completion.destroy!
  end

  it "creating a withdrawal fires `chore_withdrawal` action: :created" do
    expect(::Jil).to receive(:trigger).with(
      user, :chore_withdrawal,
      satisfy { |a| a[:action] == :created && a[:amount_pebbles] == 5 && a[:note] == "snack" }
    )
    create(:chore_withdrawal, user: user, amount_pebbles: 5, note: "snack")
  end

  it "updating + destroying a withdrawal fires :updated / :destroyed" do
    withdrawal = create(:chore_withdrawal, user: user, amount_pebbles: 5)
    expect(::Jil).to receive(:trigger).with(
      user, :chore_withdrawal, satisfy { |a| a[:action] == :updated }
    )
    withdrawal.update!(amount_pebbles: 6)
    expect(::Jil).to receive(:trigger).with(
      user, :chore_withdrawal, satisfy { |a| a[:action] == :destroyed }
    )
    withdrawal.destroy!
  end

  it "creating a transfer fires `chore_transfer` for BOTH endpoints with direction set" do
    sender = create(:user)
    recipient = create(:user)
    share_chore_household!(sender, recipient)
    chore = create(:chore, created_by_user: sender, reward_pebbles: 50)
    create(:chore_completion, chore: chore, user: sender, paid_pebbles: 50, base_pebbles: 50,
           payout_skipped: false, day_key: ChoreDay.current(sender) - 1)
    expect(::Jil).to receive(:trigger).with(
      sender, :chore_transfer,
      satisfy { |a| a[:action] == :created && a[:direction] == :outgoing && a[:counterparty_username] == recipient.username }
    )
    expect(::Jil).to receive(:trigger).with(
      recipient, :chore_transfer,
      satisfy { |a| a[:action] == :created && a[:direction] == :incoming && a[:counterparty_username] == sender.username }
    )
    ChoreTransfer.create!(from_user: sender, to_user: recipient, amount_pebbles: 10)
  end
end
