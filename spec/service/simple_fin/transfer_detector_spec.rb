require "rails_helper"

# Modelled on the real pair in the payload: checking -1393.25 "JPMORGAN CHASE
# ACH" against mortgage +1393.25 "PAYMENT", same day.
RSpec.describe SimpleFin::TransferDetector do
  let(:user) { User.me }
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "A1", name: "PREMIER PLUS CKG (2363)",
      last4: "2363", kind: :checking
    )
  }
  let!(:mortgage) {
    BankAccount.create!(
      simplefin_id: "A2", name: "MORTGAGE LOAN (7153)",
      last4: "7153", kind: :loan
    )
  }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "A3", name: "AMZ Prime (7283)",
      last4: "7283", kind: :credit
    )
  }

  def row(account, cents, at: 1.day.ago, id: SecureRandom.hex(4), payee: "PAYMENT")
    BankTransaction.create!(
      simplefin_id: id, bank_account: account, posted_at: at,
      transacted_at: at, amount_cents: cents, payee: payee
    )
  end

  it "pairs a payment leaving one account with its arrival in another" do
    out = row(checking, -139_325, payee: "JPMORGAN CHASE ACH")
    into = row(mortgage, 139_325)

    result = described_class.call

    expect(out.reload.transfer_counterpart).to eq(into)
    expect(into.reload.transfer_counterpart).to eq(out)
    expect(result.paired).to eq(1)
  end

  it "marks both halves as transfers" do
    out = row(checking, -139_325)
    into = row(mortgage, 139_325)
    described_class.call

    expect(out.reload).to be_transfer
    expect(into.reload).to be_transfer
  end

  # The whole point: a card payoff must not read as a second purchase.
  it "keeps a paired movement out of spending and income totals" do
    row(checking, -139_325)
    row(mortgage, 139_325)
    groceries = row(checking, -8_210, payee: "Costco")
    described_class.call

    expect(BankTransaction.real_money.spending.sum(:amount_cents)).to eq(-8_210)
    expect(BankTransaction.real_money.income.sum(:amount_cents)).to be_zero
    expect(BankTransaction.real_money).to contain_exactly(groceries)
  end

  it "does not pair two rows on the same account" do
    row(checking, -5_000)
    row(checking, 5_000)

    expect(described_class.call.paired).to be_zero
    expect(BankTransaction.paired).to be_empty
  end

  it "does not pair amounts that differ" do
    row(checking, -5_000)
    row(mortgage, 4_999)

    expect(described_class.call.paired).to be_zero
  end

  it "does not pair two outflows" do
    row(checking, -5_000)
    row(mortgage, -5_000)

    expect(described_class.call.paired).to be_zero
  end

  it "does not pair across a long gap" do
    row(checking, -5_000, at: 30.days.ago)
    row(mortgage, 5_000, at: 1.day.ago)

    expect(described_class.call.paired).to be_zero
  end

  # Mislabelling a real expense as a transfer erases it from spending, which is
  # worse and quieter than leaving a transfer counted.
  it "refuses when two arrivals could equally explain one departure" do
    row(checking, -5_000)
    row(mortgage, 5_000)
    row(card, 5_000)

    result = described_class.call

    expect(result.paired).to be_zero
    expect(result.ambiguous).to eq(1)
    expect(BankTransaction.paired).to be_empty
  end

  it "gives one arrival to only one departure" do
    row(checking, -5_000, id: "out-1")
    row(checking, -5_000, id: "out-2")
    row(mortgage, 5_000)

    described_class.call
    expect(BankTransaction.paired.count).to eq(2)
  end

  it "is idempotent" do
    row(checking, -139_325)
    row(mortgage, 139_325)

    described_class.call
    expect(described_class.call.paired).to be_zero
    expect(BankTransaction.paired.count).to eq(2)
  end

  it "honours a transfer flagged by hand on the alert" do
    event = ActionEvent.create!(
      user: user, name: "Transaction", timestamp: 1.day.ago,
      data: { amount: 50.0, account: "(...2363)", transfer: true, category: "card payment" }
    )
    flagged = row(checking, -5_000)
    flagged.update!(action_event: event)

    expect(flagged.reload).to be_transfer
    expect(BankTransaction.real_money).not_to include(flagged)
  end

  it "survives one half being deleted" do
    out = row(checking, -139_325)
    into = row(mortgage, 139_325)
    described_class.call

    expect { into.destroy! }.not_to raise_error
    expect(out.reload.transfer_counterpart_id).to be_nil
  end
end
