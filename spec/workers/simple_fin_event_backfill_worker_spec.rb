require "rails_helper"

# The chain is the whole point: one batch per run, re-enqueueing itself until
# the walk is through. A worker that ran once and stopped would leave the
# backfill silently 250 events in.
RSpec.describe SimpleFinEventBackfillWorker do
  let(:user) { User.me }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "A2", name: "AMZ Prime (7283)", last4: "7283", kind: :credit,
    )
  }

  before { SimpleFin::EventBackfill.reset! }

  def alert(amount)
    ActionEvent.create!(
      user: user, name: "Transaction", timestamp: 2.days.ago,
      data: { amount: amount, account: "(...7283)", category: "shopping", merchant: "SOMEWHERE" }
    )
  end

  it "projects a batch when it runs" do
    alert(24.99)

    expect { described_class.new.perform }.to(change(BankTransaction, :count).by(1))
  end

  it "queues the next batch while there is more to do" do
    alert(24.99)

    expect(described_class).to receive(:perform_in).with(described_class::NEXT_IN)

    described_class.new.perform
  end

  it "stops the chain once the walk is through" do
    alert(24.99)
    SimpleFin::EventBackfill.call_all

    expect(described_class).not_to receive(:perform_in)

    described_class.new.perform
  end

  describe ".restart!" do
    it "clears the cursor and starts again" do
      alert(24.99)
      SimpleFin::EventBackfill.call_all
      expect(SimpleFin::EventBackfill.state[:done]).to be(true)

      allow(described_class).to receive(:perform_async)
      described_class.restart!

      expect(SimpleFin::EventBackfill.state[:done]).to be(false)
      expect(described_class).to have_received(:perform_async)
    end

    # Restarting must not duplicate what it already made — sync is idempotent
    # and the re-walk is how you confirm the walk is complete.
    it "creates nothing the second time round" do
      alert(24.99)
      SimpleFin::EventBackfill.call_all
      SimpleFin::EventBackfill.reset!

      expect { SimpleFin::EventBackfill.call_all }.not_to(change(BankTransaction, :count))
    end
  end
end
