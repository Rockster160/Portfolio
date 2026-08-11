require "rails_helper"

# The dashboard floors to the thousand, so only a charge that tips the balance
# across a boundary is worth spending a request on.
RSpec.describe SimpleFin::BalanceWatch do
  let(:user) { User.me }
  # $2,034.00 — the worked example: a $35 charge turns the 2 into a 1.
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "A1", name: "PREMIER PLUS CKG (2363)",
      last4: "2363", kind: :checking, balance_cents: 203_400
    )
  }

  def alert(amount, label: "(...2363)", name: "Transaction")
    ActionEvent.create!(
      user: user, name: name, timestamp: Time.current,
      data: { amount: amount, account: label, category: "groceries" }
    )
  end

  describe ".crosses_thousand?" do
    it "is true when the charge tips it into the next thousand down" do
      expect(described_class.crosses_thousand?(203_400, 3_500)).to be(true)
    end

    it "is false when it stays inside the same thousand" do
      expect(described_class.crosses_thousand?(203_400, 3_300)).to be(false)
    end

    it "is true for a charge larger than the whole remainder" do
      expect(described_class.crosses_thousand?(203_400, 150_000)).to be(true)
    end

    it "reads an overdraft as one lower rather than one closer to zero" do
      expect(described_class.crosses_thousand?(5_000, 10_000)).to be(true)
    end
  end

  describe ".consider" do
    it "starts a chase for a boundary-crossing charge" do
      expect(SimpleFinBalanceChaseWorker).to receive(:start!).and_return(true)

      expect(described_class.consider(alert(35.0))).to be(true)
    end

    it "ignores a charge that leaves the displayed figure alone" do
      expect(SimpleFinBalanceChaseWorker).not_to receive(:start!)

      expect(described_class.consider(alert(33.0))).to be(false)
    end

    it "ignores an alert for an account we do not hold" do
      expect(SimpleFinBalanceChaseWorker).not_to receive(:start!)

      expect(described_class.consider(alert(35.0, label: "Prime Visa (...7283)"))).to be(false)
    end

    # The figure is cumulative, so a card charge pulls it down exactly as a
    # checking charge does — watching only checking would miss half of them.
    it "starts a chase for a card charge that crosses the boundary" do
      BankAccount.create!(
        simplefin_id: "A2", name: "AMZ Prime (7283)",
        last4: "7283", kind: :credit, balance_cents: -50_000
      )
      expect(SimpleFinBalanceChaseWorker).to receive(:start!).and_return(true)

      # Total is $1,534.00; a $600 charge turns the 1 into a 0.
      expect(described_class.consider(alert(600.0, label: "Prime Visa (...7283)"))).to be(true)
    end

    # The card deepens the debt, so the total sits a thousand lower than
    # checking alone and a charge that would have crossed no longer does.
    it "measures the crossing against the total, not the one account" do
      BankAccount.create!(
        simplefin_id: "A2", name: "AMZ Prime (7283)",
        last4: "7283", kind: :credit, balance_cents: -50_000
      )
      expect(SimpleFinBalanceChaseWorker).not_to receive(:start!)

      # $35 crosses 203,400 but not the 153,400 total.
      expect(described_class.consider(alert(35.0))).to be(false)
    end

    it "ignores an event that is not a transaction" do
      expect(described_class.consider(alert(35.0, name: "Whisper"))).to be(false)
    end

    # If a bank row already exists the charge is synced, so the balance
    # SimpleFIN reported already accounts for it.
    it "ignores an alert whose charge has already been synced" do
      event = alert(35.0)
      BankTransaction.create!(
        simplefin_id: "T1", bank_account: checking, action_event: event,
        posted_at: Time.current, amount_cents: -3_500
      )

      expect(described_class.consider(event)).to be(false)
    end

    # A loan is not part of the reported figure, so a charge on one cannot move
    # it — and an unclassified account is not part of it either.
    it "does nothing when the alert's account is outside the reported figure" do
      checking.update!(kind: :loan)

      expect(described_class.consider(alert(35.0))).to be(false)
    end

    it "does nothing when the alert's account is still unclassified" do
      checking.update!(kind: :unknown)

      expect(described_class.consider(alert(35.0))).to be(false)
    end

    # Savings counts as much as checking — both are money in the total.
    it "watches savings the same as checking" do
      checking.update!(kind: :savings)
      expect(SimpleFinBalanceChaseWorker).to receive(:start!).and_return(true)

      expect(described_class.consider(alert(35.0))).to be(true)
    end

    it "fires through ActionEventNotifier" do
      expect(SimpleFinBalanceChaseWorker).to receive(:start!).and_return(true)

      event = alert(35.0)
      ActionEventNotifier.notify(user, event, :added)
    end
  end
end
