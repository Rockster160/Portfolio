require "rails_helper"

# Chase alerts and SimpleFIN describe the same purchases from two sides. This
# is the seam where they become one row, so the cases that matter are the ones
# where they meet: a merge that should happen, and every merge that should not.
RSpec.describe SimpleFin::EventTransaction do
  let(:user) { User.me }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "A2", name: "AMZ Prime (7283)", last4: "7283", kind: :credit,
    )
  }
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "A1", name: "PREMIER PLUS CKG (2363)", last4: "2363", kind: :checking,
    )
  }

  # An alert as Jil writes it: amount POSITIVE for money spent, and an account
  # string that may or may not name anything.
  def alert(
    amount: 24.99,
    account: "(...7283)",
    category: "shopping",
    merchant: "AMAZON MKTPLACE PMTS",
    at: Time.utc(2026, 8, 10, 21, 15),
    name: "Transaction")
    ActionEvent.create!(
      user: user, name: name, timestamp: at,
      data: { amount: amount, account: account, category: category, merchant: merchant }
    )
  end

  describe ".sync" do
    it "lands a transaction the moment the alert arrives" do
      row = described_class.sync(alert)

      expect(row.payee).to eq("AMAZON MKTPLACE PMTS")
      expect(row.category).to eq("shopping")
      expect(row.bank_account).to eq(card)
      expect(row.transacted_at).to eq(Time.utc(2026, 8, 10, 21, 15))
    end

    # The alert says "you spent 24.99"; the card it left records -24.99.
    it "flips the sign the alert stores it under" do
      expect(described_class.sync(alert(amount: 24.99)).amount_cents).to eq(-2499)
    end

    it "reads a deposit as money arriving" do
      expect(described_class.sync(alert(amount: -4370.70)).amount_cents).to eq(437_070)
    end

    # An alert fires when the purchase is made and says nothing about when it
    # will clear — which can be four days later.
    it "claims no posted date and no SimpleFIN id" do
      row = described_class.sync(alert)

      expect(row.posted_at).to be_nil
      expect(row.simplefin_id).to be_nil
      expect(BankTransaction.bank_confirmed).to be_empty
    end

    it "takes its timestamp from the alert" do
      row = described_class.sync(alert(at: Time.utc(2026, 8, 10, 21, 15)))

      expect(row.occurred_at).to eq(Time.utc(2026, 8, 10, 21, 15))
    end

    # 433 of 2,563 events come from an alert format that names no account.
    # Blank is the answer; the likeliest account is not.
    it "leaves the account blank when the alert names none" do
      row = described_class.sync(alert(account: ""))

      expect(row.bank_account).to be_nil
      expect(row.category).to eq("shopping")
    end

    it "leaves the account blank when the alert names one we do not hold" do
      row = described_class.sync(alert(account: "Chase Sapphire Preferred (...4842)"))

      expect(row.bank_account).to be_nil
    end

    it "ignores anything that is not a Transaction event" do
      expect(described_class.sync(alert(name: "Whisper"))).to be_nil
      expect(BankTransaction.count).to be_zero
    end

    it "creates one row however many times it runs" do
      event = alert

      expect { 3.times { described_class.sync(event) } }.to(change(BankTransaction, :count).by(1))
    end

    it "carries an edited category down to the row" do
      event = alert(category: "shopping")
      row = described_class.sync(event)

      event.update!(data: event.data.merge("category" => "home"))
      described_class.sync(event)

      expect(row.reload.category).to eq("home")
    end

    # Clearing a field on the alert is not a request to uncategorize the
    # transaction it produced.
    it "does not erase a category the alert has stopped naming" do
      event = alert(category: "shopping")
      row = described_class.sync(event)

      event.update!(data: event.data.merge("category" => nil))
      described_class.sync(event)

      expect(row.reload.category).to eq("shopping")
    end

    # The alert arriving second must not produce a sibling of the row SimpleFIN
    # already reported.
    it "links to a bank row already holding the same purchase" do
      existing = BankTransaction.create!(
        simplefin_id: "TRN-1", bank_account: card, posted_at: Time.utc(2026, 8, 11),
        transacted_at: Time.utc(2026, 8, 10, 21, 15), amount_cents: -2499, payee: "AMAZON"
      )

      row = described_class.sync(alert)

      expect(row.id).to eq(existing.id)
      expect(BankTransaction.count).to eq(1)
      expect(existing.reload.category).to eq("shopping")
    end

    # Only the annotation is the event's. Re-deriving the rest would undo the
    # corrections SimpleFIN makes as a charge settles.
    it "does not overwrite the bank's own figures on a linked row" do
      existing = BankTransaction.create!(
        simplefin_id: "TRN-1", bank_account: card, posted_at: Time.utc(2026, 8, 11),
        transacted_at: Time.utc(2026, 8, 10, 21, 15), amount_cents: -2499,
        payee: "AMAZON MKTPLACE PMTS PA"
      )
      described_class.sync(alert(amount: 99.99))

      expect(existing.reload.payee).to eq("AMAZON MKTPLACE PMTS PA")
      expect(existing.amount_cents).to eq(-2499)
    end
  end

  describe ".forget" do
    it "takes the row with it when the row was only ever the alert" do
      event = alert
      described_class.sync(event)

      expect { described_class.forget(event) }.to(change(BankTransaction, :count).by(-1))
    end

    # Once the bank has reported it, the row is the institution's record and
    # outlives the annotation — which is what the FK's ON DELETE SET NULL says.
    it "leaves a bank-confirmed row standing" do
      event = alert
      row = described_class.sync(event)
      row.update!(simplefin_id: "TRN-1")

      described_class.forget(event)

      expect(row.reload).to be_present
    end

    it "ignores anything that is not a Transaction event" do
      expect(described_class.forget(alert(name: "Whisper"))).to be_nil
    end
  end

  describe ".claim" do
    let(:at) { Time.utc(2026, 8, 10, 21, 15) }

    def claim(bank_account: card, amount_cents: -2499, occurred_at: nil)
      described_class.claim(
        bank_account: bank_account, amount_cents: amount_cents, occurred_at: occurred_at || at,
      )
    end

    it "finds the alert-sourced row the bank is now confirming" do
      row = described_class.sync(alert)

      expect(claim).to eq(row)
    end

    it "still finds it when the bank clears a few days later" do
      row = described_class.sync(alert)

      expect(claim(occurred_at: at + 3.days)).to eq(row)
    end

    it "finds nothing once the gap is wider than the window" do
      described_class.sync(alert)

      expect(claim(occurred_at: at + 9.days)).to be_nil
    end

    it "never claims a row the bank has already confirmed" do
      described_class.sync(alert).update!(simplefin_id: "TRN-1")

      expect(claim).to be_nil
    end

    # A refund is the same magnitude as the charge it reverses and lands within
    # days of it. Matching on magnitude is how the two become one row and the
    # refund disappears.
    it "does not claim a charge for its own refund" do
      described_class.sync(alert(amount: 24.99))

      expect(claim(amount_cents: 2499)).to be_nil
    end

    # Refusing here would let the bank's copy be inserted alongside the alert's,
    # which is a phantom transaction in every total. Closest in time wins.
    it "takes the closest of two candidates rather than neither" do
      near = described_class.sync(alert(at: at))
      described_class.sync(alert(at: at + 2.days))

      expect(claim).to eq(near)
    end

    it "prefers the row that names the account over one that names none" do
      described_class.sync(alert(account: "", at: at))
      exact = described_class.sync(alert(account: "(...7283)", at: at + 1.hour))

      expect(claim).to eq(exact)
    end

    # The 433 checking alerts that name no account are the whole reason for
    # this fallback — without it they duplicate every checking row SimpleFIN
    # reports.
    it "falls back to an unattributed row when nothing else fits" do
      row = described_class.sync(alert(account: ""))

      expect(claim(bank_account: checking)).to eq(row)
    end
  end
end
