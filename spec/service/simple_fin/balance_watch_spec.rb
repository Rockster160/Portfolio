require "rails_helper"

# The dashboard floors to the thousand, so a chase is worth a request only when
# what we are SHOWING and what the bank last REPORTED are different numbers at
# that resolution.
RSpec.describe SimpleFin::BalanceWatch do
  let(:user) { User.me }
  # $2,034.00 — the worked example: a $35 charge turns the 2 into a 1.
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "A1", name: "PREMIER PLUS CKG (2363)",
      last4: "2363", kind: :checking, balance_cents: 203_400,
      available_balance_cents: 203_400, balance_date: 2.hours.ago
    )
  }

  def card(balance_cents)
    BankAccount.create!(
      simplefin_id: "A2", name: "AMZ Prime (7283)", last4: "7283", kind: :credit,
      balance_cents: balance_cents, balance_date: 2.hours.ago
    )
  end

  # The row exists before `consider` runs — ActionEventNotifier syncs it first —
  # so it has to exist here too. Without it the projection has nothing to carry
  # forward and no alert could ever diverge from the reported figure.
  #
  # Amounts are stored the way the alerts store them: unsigned and INVERTED, so
  # 35.0 is $35 leaving and -1000.0 is $1,000 arriving.
  def alert(amount, label: "(...2363)", name: "Transaction")
    event = ActionEvent.create!(
      user: user, name: name, timestamp: Time.current,
      data: { amount: amount, account: label, category: "groceries" }
    )
    SimpleFin::EventTransaction.sync(event)
    event
  end

  describe ".diverged?" do
    it "is false while nothing has happened since the bank's figure" do
      expect(described_class.diverged?).to be(false)
    end

    it "is false for a charge that leaves the floored figure alone" do
      alert(33.0)

      expect(described_class.diverged?).to be(false)
    end

    it "is true once the charges since add up to a different thousand" do
      alert(20.0)
      alert(20.0)

      expect(described_class.diverged?).to be(true)
    end

    # It reads the transactions, not the alert, so a row that is not counted
    # anywhere else is not counted here either.
    it "ignores a charge that has been voided" do
      alert(35.0)
      BankTransaction.last.update!(voided_at: Time.current)

      expect(described_class.diverged?).to be(false)
    end

    # Nothing to project from and nothing to compare against.
    it "is false when an account has never reported a balance" do
      card(nil)
      alert(35.0)

      expect(described_class.diverged?).to be(false)
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

    # The old test subtracted the alert's own amount from the reported figure,
    # which could only ever read a deposit as money leaving. The projection is
    # signed, so an arriving $1,000 now moves the figure the way it actually
    # moves it.
    it "starts a chase for a deposit that crosses the boundary upward" do
      expect(SimpleFinBalanceChaseWorker).to receive(:start!).and_return(true)

      expect(described_class.consider(alert(-1_000.0))).to be(true)
    end

    it "ignores an alert for an account we do not hold" do
      expect(SimpleFinBalanceChaseWorker).not_to receive(:start!)

      expect(described_class.consider(alert(35.0, label: "Prime Visa (...7283)"))).to be(false)
    end

    # The figure is cumulative, so a card charge pulls it down exactly as a
    # checking charge does — watching only checking would miss half of them.
    it "starts a chase for a card charge that crosses the boundary" do
      card(-50_000)
      expect(SimpleFinBalanceChaseWorker).to receive(:start!).and_return(true)

      # Total is $1,534.00; a $600 charge turns the 1 into a 0.
      expect(described_class.consider(alert(600.0, label: "Prime Visa (...7283)"))).to be(true)
    end

    # The card deepens the debt, so the total sits a thousand lower than
    # checking alone and a charge that would have crossed no longer does.
    it "measures the crossing against the total, not the one account" do
      card(-50_000)
      expect(SimpleFinBalanceChaseWorker).not_to receive(:start!)

      # $35 crosses 203,400 but not the 153,400 total.
      expect(described_class.consider(alert(35.0))).to be(false)
    end

    it "ignores an event that is not a transaction" do
      expect(described_class.consider(alert(35.0, name: "Whisper"))).to be(false)
    end

    # If the bank has already reported this charge, the balance it sent
    # alongside already accounts for it and there is nothing to chase.
    it "ignores an alert whose charge has already been synced" do
      event = alert(35.0)
      BankTransaction.find_by!(action_event_id: event.id).update!(simplefin_id: "T1")

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

      event = ActionEvent.create!(
        user: user, name: "Transaction", timestamp: Time.current,
        data: { amount: 35.0, account: "(...2363)", category: "groceries" }
      )
      ActionEventNotifier.notify(user, event, :added)
    end
  end
end
