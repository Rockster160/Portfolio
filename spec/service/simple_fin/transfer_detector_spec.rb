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

  # A card payoff must not read as a second purchase.
  it "pairs a payment with its arrival in another account, marking both transfers out of the totals", :aggregate_failures do
    out = row(checking, -139_325, payee: "CHASE CREDIT CRD AUTOPAY")
    into = row(card, 139_325)
    groceries = row(checking, -8_210, payee: "Costco")

    result = described_class.call

    expect(result.paired).to eq(1)
    expect(out.reload.transfer_counterpart).to eq(into)
    expect(into.reload.transfer_counterpart).to eq(out)
    expect(out).to be_transfer
    expect(into).to be_transfer
    expect(BankTransaction.real_money.spending.sum(:amount_cents)).to eq(-8_210)
    expect(BankTransaction.real_money.income.sum(:amount_cents)).to be_zero
    expect(BankTransaction.real_money).to contain_exactly(groceries)
  end

  it "pairs nothing on one account, of differing amounts, two outflows, or across a long gap" do
    [
      [[checking, -5_000], [checking, 5_000]],
      [[checking, -5_000], [mortgage, 4_999]],
      [[checking, -5_000], [mortgage, -5_000]],
      [[checking, -5_000, 30.days.ago], [mortgage, 5_000, 1.day.ago]],
    ].each do |pair|
      BankTransaction.delete_all
      pair.each { |account, cents, at| row(account, cents, at: at || 1.day.ago) }

      expect(described_class.call.paired).to be_zero, pair.map { |a, c, _| [a.name, c] }.inspect
      expect(BankTransaction.paired).to be_empty
    end
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
