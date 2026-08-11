require "rails_helper"

# The email alert lands first and carries the category; SimpleFIN reports the
# same charge up to a day later. These pin down that a link only happens when
# it is unambiguous.
RSpec.describe SimpleFin::EventMatcher do
  let(:user) { User.me }
  let(:account) {
    BankAccount.create!(
      simplefin_id: "ACT-0001",
      name:         "Chase Sapphire Preferred (8257)",
      last4:        "8257",
      kind:         :credit,
    )
  }

  def event(amount:, at:, account_label: "Chase Sapphire Preferred Visa (...8257)", category: "eat out")
    ActionEvent.create!(
      user:      user,
      name:      "Transaction",
      timestamp: at,
      data:      {
        amount:   amount,
        account:  account_label,
        category: category,
        merchant: "TST* HOUSTON S HOT C",
      },
    )
  end

  def transaction(amount_cents:, at:, simplefin_id: "TRN-0001", on: account)
    BankTransaction.create!(
      simplefin_id:  simplefin_id,
      bank_account:  on,
      posted_at:     at,
      transacted_at: at,
      amount_cents:  amount_cents,
      description:   "TST* HOUSTON S HOT C",
    )
  end

  it "links a charge to the alert that described it" do
    matching = event(amount: 29.72, at: 2.days.ago)
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    result = described_class.call

    expect(row.reload.action_event).to eq(matching)
    expect(result.linked).to eq(1)
  end

  it "carries the category through without copying it" do
    event(amount: 29.72, at: 2.days.ago, category: "groceries")
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    described_class.call
    expect(row.reload.category).to eq("groceries")
  end

  it "matches across the account label spellings the events actually use" do
    matching = event(amount: 29.72, at: 2.days.ago, account_label: "(...8257)")
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    described_class.call
    expect(row.reload.action_event).to eq(matching)
  end

  it "leaves a charge alone when two alerts could explain it" do
    event(amount: 29.72, at: 2.days.ago)
    event(amount: 29.72, at: 1.day.ago)
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    result = described_class.call

    expect(row.reload.action_event).to be_nil
    expect(result.ambiguous).to eq(1)
  end

  it "does not match a different amount" do
    event(amount: 29.72, at: 2.days.ago)
    row = transaction(amount_cents: -2900, at: 1.day.ago)

    described_class.call
    expect(row.reload.action_event).to be_nil
  end

  it "does not match a different account" do
    event(amount: 29.72, at: 2.days.ago, account_label: "Prime Visa (...7283)")
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    described_class.call
    expect(row.reload.action_event).to be_nil
  end

  it "does not match outside the window" do
    event(amount: 29.72, at: 20.days.ago)
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    result = described_class.call

    expect(row.reload.action_event).to be_nil
    expect(result.unmatched).to eq(1)
  end

  it "never gives one alert to two charges" do
    event(amount: 29.72, at: 2.days.ago)
    first = transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-0001")
    second = transaction(amount_cents: -2972, at: 1.day.ago, simplefin_id: "TRN-0002")

    described_class.call

    linked = [first.reload.action_event_id, second.reload.action_event_id]
    expect(linked.compact.size).to eq(1)
  end

  it "does not re-link an already-claimed alert on a later run" do
    matching = event(amount: 29.72, at: 2.days.ago)
    transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-0001")
    described_class.call

    later = transaction(amount_cents: -2972, at: 1.day.ago, simplefin_id: "TRN-0002")
    described_class.call

    expect(later.reload.action_event).to be_nil
    expect(BankTransaction.linked.pluck(:action_event_id)).to eq([matching.id])
  end

  it "skips an account with no trailing digits rather than matching on amount alone" do
    unnumbered = BankAccount.create!(simplefin_id: "ACT-0002", name: "MORTGAGE LOAN", last4: nil)
    event(amount: 29.72, at: 2.days.ago)
    row = transaction(amount_cents: -2972, at: 1.day.ago, on: unnumbered)

    result = described_class.call

    expect(row.reload.action_event).to be_nil
    expect(result.unmatched).to eq(1)
  end

  it "ignores ActionEvents that are not transactions" do
    ActionEvent.create!(
      user: user, name: "Whisper", timestamp: 2.days.ago, data: { amount: 29.72 },
    )
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    described_class.call
    expect(row.reload.action_event).to be_nil
  end

  it "only considers transactions it was handed" do
    event(amount: 29.72, at: 2.days.ago)
    row = transaction(amount_cents: -2972, at: 1.day.ago)

    described_class.call(BankTransaction.where(simplefin_id: "nope"))
    expect(row.reload.action_event).to be_nil
  end
end
