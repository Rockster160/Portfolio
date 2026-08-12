require "rails_helper"

# The one-time walk over 2,563 historical alerts. What matters is that it always
# advances, always finishes, and that stopping it half way is safe.
RSpec.describe SimpleFin::EventBackfill do
  let(:user) { User.me }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "A2", name: "AMZ Prime (7283)", last4: "7283", kind: :credit,
    )
  }

  before { described_class.reset! }

  def alert(amount: 24.99, account: "(...7283)", at: 2.days.ago, name: "Transaction")
    ActionEvent.create!(
      user: user, name: name, timestamp: at,
      data: { amount: amount, account: account, category: "shopping", merchant: "SOMEWHERE" }
    )
  end

  describe ".call" do
    it "projects a batch and stops there" do
      4.times { |i| alert(amount: 10 + i) }

      outcome = described_class.call(limit: 2)

      expect(outcome.examined).to eq(2)
      expect(outcome.created).to eq(2)
      expect(BankTransaction.count).to eq(2)
    end

    it "picks up after the cursor on the next pass" do
      4.times { |i| alert(amount: 10 + i) }

      described_class.call(limit: 2)
      described_class.call(limit: 2)

      expect(BankTransaction.count).to eq(4)
    end

    it "reports done once there is nothing after the cursor" do
      2.times { |i| alert(amount: 10 + i) }
      described_class.call(limit: 10)

      expect(described_class.call(limit: 10)).to be_done
    end

    it "is done immediately when there are no events at all" do
      expect(described_class.call).to be_done
    end

    it "stays done rather than walking again" do
      alert
      described_class.call
      described_class.call

      expect { described_class.call }.not_to(change(BankTransaction, :count))
    end

    it "ignores events that are not transactions" do
      alert(name: "Whisper")

      described_class.call

      expect(BankTransaction.count).to be_zero
    end

    # The reason the cursor is an ID rather than "events with no row". An event
    # that cannot be projected would otherwise be re-selected on every pass and
    # the walk would never reach the end.
    it "moves past an event it cannot project" do
      broken = alert
      broken.update!(data: broken.data.merge("amount" => nil))
      alert(amount: 55.0)

      described_class.call(limit: 1)
      outcome = described_class.call(limit: 1)

      expect(outcome.examined).to eq(1)
      expect(BankTransaction.count).to eq(1)
    end

    it "counts an event already holding a row as skipped rather than redoing it" do
      event = alert
      SimpleFin::EventTransaction.sync(event)

      outcome = described_class.call

      expect(outcome.skipped).to eq(1)
      expect(outcome.created).to be_zero
    end

    # Interrupting it costs one batch, not the walk.
    it "keeps what it did when the walk is reset and run again" do
      3.times { |i| alert(amount: 10 + i) }
      described_class.call(limit: 2)

      described_class.reset!

      expect { described_class.call(limit: 10) }.to(change(BankTransaction, :count).by(1))
    end
  end

  describe ".call_all" do
    it "runs the whole thing in one go" do
      5.times { |i| alert(amount: 10 + i) }

      totals = described_class.call_all(limit: 2)

      expect(totals[:created]).to eq(5)
      expect(BankTransaction.count).to eq(5)
    end
  end

  describe ".progress" do
    it "reports nothing to show when there are no events" do
      expect(described_class.progress).to be_idle
    end

    # Counted, not stored, so it stays true after a reset or a late arrival.
    it "counts what is projected against what exists" do
      4.times { |i| alert(amount: 10 + i) }
      described_class.call(limit: 2)

      progress = described_class.progress
      expect(progress.projected).to eq(2)
      expect(progress.total).to eq(4)
      expect(progress.remaining).to eq(2)
      expect(progress.percent).to eq(50)
    end

    it "reads 100% once the walk is through" do
      2.times { |i| alert(amount: 10 + i) }
      described_class.call_all

      expect(described_class.progress.percent).to eq(100)
    end
  end
end
