require "rails_helper"

# Chases the new balance after an alert that should have moved the dashboard
# figure, retrying hourly because SimpleFIN can be a day behind — and stopping,
# because every attempt costs a request against a ~24/day budget.
RSpec.describe SimpleFinBalanceChaseWorker do
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "A1", name: "PREMIER PLUS CKG (2363)",
      last4: "2363", kind: :checking, balance_cents: 203_400
    )
  }

  before do
    allow(described_class).to receive(:perform_async)
    allow(described_class).to receive(:perform_in)
    allow(SimpleFin::Client).to receive(:configured?).and_return(true)
    allow(SimpleFin::Refresh).to receive(:call)
  end

  # Enqueue-time dedupe belongs to sidekiq-unique-jobs middleware and needs
  # Redis, which these specs stub out; the lock args are what can be pinned.
  describe "uniqueness configuration" do
    it "collapses the attempt arg so every link shares one lock" do
      collapse = described_class.get_sidekiq_options["lock_args_method"]

      expect(collapse.call([1])).to eq([])
      expect(collapse.call([4])).to eq(collapse.call([1]))
    end
  end

  describe ".start!" do
    it "enqueues a chase at attempt 1" do
      described_class.start!

      expect(described_class).to have_received(:perform_async).with(1)
    end
  end

  describe "#perform" do
    it "stops once the figure has moved" do
      allow(SimpleFin::Refresh).to receive(:call) { checking.update!(balance_cents: 199_900) }

      described_class.new.perform(1)

      expect(described_class).not_to have_received(:perform_in)
    end

    it "reschedules an hour out when the figure has not moved yet" do
      described_class.new.perform(1)

      expect(described_class).to have_received(:perform_in).with(described_class::RETRY_IN, 2)
    end

    it "spends no more than MAX_ATTEMPTS requests across a whole chain, then gives up" do
      (1..described_class::MAX_ATTEMPTS).each { |attempt| described_class.new.perform(attempt) }

      expect(SimpleFin::Refresh).to have_received(:call).exactly(described_class::MAX_ATTEMPTS).times
      expect(described_class).to have_received(:perform_in).exactly(described_class::MAX_ATTEMPTS - 1).times
      expect(described_class).not_to have_received(:perform_in).with(anything, described_class::MAX_ATTEMPTS + 1)
    end

    it "does nothing when SimpleFIN is not configured" do
      allow(SimpleFin::Client).to receive(:configured?).and_return(false)

      described_class.new.perform(1)

      expect(SimpleFin::Refresh).not_to have_received(:call)
      expect(described_class).not_to have_received(:perform_in)
    end
  end
end
