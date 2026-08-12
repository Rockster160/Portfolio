require "rails_helper"

# The Bridge caps a range at 90 days, so history is collected a window at a
# time, walking backwards from the oldest thing already held.
RSpec.describe SimpleFin::Backfill do
  let!(:account) {
    BankAccount.create!(
      simplefin_id: "ACT-1", name: "PREMIER PLUS CKG (2363)",
      last4: "2363", kind: :checking, balance_cents: 1_832_024
    )
  }

  # The oldest row currently held — the anchor the first window hangs off.
  let(:anchor) { Time.utc(2026, 5, 14, 12) }

  def transaction(id, at)
    BankTransaction.create!(
      simplefin_id: id, bank_account: account,
      posted_at: at, transacted_at: at, amount_cents: -1_000
    )
  end

  # Captures what the client was asked for, and answers with however many
  # transactions the case needs.
  def stub_fetch(created: 0)
    requests = []
    allow(SimpleFin::Client).to receive(:configured?).and_return(true)
    allow(SimpleFin::Client).to receive(:accounts) { |**args|
      requests << args
      { "accounts" => [payload(args, created)] }
    }
    requests
  end

  def payload(args, created)
    rows = created.times.map { |i|
      posted = (args[:start_date] + (i + 1).days).to_i
      {
        "id"          => "TRN-#{args[:start_date].to_i}-#{i}",
        "posted"      => posted,
        "amount"      => "-10.00",
        "description" => "Old thing",
      }
    }
    {
      "id"           => "ACT-1",
      "name"         => "PREMIER PLUS CKG (2363)",
      "balance"      => "18320.24",
      "transactions" => rows,
    }
  end

  before { described_class.reset! }

  describe ".call" do
    it "does nothing without an access url" do
      allow(SimpleFin::Client).to receive(:configured?).and_return(false)

      expect(described_class.call.status).to eq(:not_configured)
    end

    # There is no anchor to walk back from until something has synced. The
    # scheduled sync lays one down.
    it "waits when no transactions exist at all" do
      stub_fetch

      expect(described_class.call.status).to eq(:idle)
    end

    it "asks for the window just before the oldest transaction held" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 3)

      described_class.call

      expect(requests.length).to eq(1)
      expect(requests.first[:start_date].to_date).to eq((anchor - 87.days).to_date)
      expect(requests.first[:end_date].to_date).to eq((anchor + 3.days).to_date)
    end

    # A transaction can post days after it was made, landing inside a window
    # already fetched. Exactly-adjacent windows would step over it.
    it "overlaps the window it already covered" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 3)

      described_class.call
      span = requests.first[:end_date] - requests.first[:start_date]

      expect(requests.first[:end_date]).to be > anchor
      expect(span).to eq(90.days)
    end

    # The client raises above 90 days, so a window that drifted over the cap
    # would abort the whole walk rather than fetch less.
    it "never asks for more than the Bridge allows" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 1)

      3.times { described_class.call }

      expect(requests).to all(satisfy { |args|
        (args[:end_date] - args[:start_date]) <= SimpleFin::Client::MAX_RANGE_DAYS.days
      })
    end

    it "walks a further window back on the next run" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 3)

      described_class.call
      described_class.call

      expect(requests.length).to eq(2)
      expect(requests.second[:start_date]).to be < requests.first[:start_date]
      expect(requests.second[:start_date].to_date).to eq((anchor - 174.days).to_date)
    end

    # The cursor is the oldest date ASKED for, not the oldest row held. An
    # empty window moves the first and not the second, and anchoring on the
    # rows would re-ask for it every day forever.
    it "keeps moving back through a window that returned nothing" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 0)

      described_class.call
      described_class.call

      expect(requests.second[:start_date]).to be < requests.first[:start_date]
    end

    it "stops after two empty windows in a row" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 0)

      3.times { described_class.call }

      expect(requests.length).to eq(2)
      expect(described_class.call.status).to eq(:done)
    end

    # One quiet quarter is not the end of the history.
    it "carries on when an empty window is followed by a full one" do
      transaction("TRN-A", anchor)
      created = 0
      allow(SimpleFin::Client).to receive(:configured?).and_return(true)
      allow(SimpleFin::Client).to receive(:accounts) { |**args|
        { "accounts" => [payload(args, created)] }
      }

      described_class.call            # empty, run 1
      created = 2
      described_class.call            # found something, resets the counter
      created = 0
      described_class.call            # empty, run 1 again

      expect(described_class.call.status).to eq(:fetched)
    end

    it "stops at the floor rather than walking toward 1970" do
      transaction("TRN-A", described_class::FLOOR + 10.days)
      requests = stub_fetch(created: 5)

      described_class.call
      result = described_class.call

      expect(requests.first[:start_date]).to eq(described_class::FLOOR)
      expect(result.status).to eq(:done)
    end

    it "picks up an older row that arrived by some other route" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 1)
      described_class.call

      # A row older than everything the walk has asked for.
      transaction("TRN-OLD", Time.utc(2020, 1, 1))
      described_class.call

      expect(requests.second[:end_date].to_date).to eq(Time.utc(2020, 1, 4).to_date)
    end

    it "resumes from the stored cursor across processes" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 1)

      described_class.call
      expect(described_class.state[:cursor].to_date).to eq((anchor - 87.days).to_date)

      described_class.call
      expect(requests.second[:start_date].to_date).to eq((anchor - 174.days).to_date)
    end

    # An unparseable cursor is not worth failing over — the oldest row is a
    # perfectly good anchor to fall back to.
    it "falls back to the oldest row when the stored cursor is garbage" do
      transaction("TRN-A", anchor)
      DataStorage[described_class::STORAGE_KEY] = { cursor: "not a date" }
      requests = stub_fetch(created: 1)

      described_class.call

      expect(requests.first[:start_date].to_date).to eq((anchor - 87.days).to_date)
    end

    it "actually stores what it fetched" do
      transaction("TRN-A", anchor)
      stub_fetch(created: 4)

      expect { described_class.call }.to change(BankTransaction, :count).by(4)
    end

    # A backfilled row is exactly the inverted case EventMatcher exists for:
    # the alert has been sitting there categorized for a year, and the bank row
    # only just arrived.
    it "links a backfilled row to the Chase alert that already described it" do
      transaction("TRN-A", anchor)
      stub_fetch(created: 1)
      # The window is [anchor - 87d, anchor + 3d]; the stub posts its row one
      # day into it. $10.00, matching the payload.
      posted = anchor - 86.days
      event = ActionEvent.create!(
        user: User.me, name: "Transaction", timestamp: posted, notes: "Old thing",
        data: { amount: 10.0, account: "(...2363)", category: "groceries" }
      )

      described_class.call

      expect(BankTransaction.find_by(action_event_id: event.id)).to be_present
    end

    # Nothing to link to before the alerts start, and that is not a failure —
    # the row is still worth having.
    it "keeps a row from before the alerts, unlinked" do
      transaction("TRN-A", anchor)
      stub_fetch(created: 1)

      expect { described_class.call }.to change(BankTransaction.unlinked, :count).by(1)
    end
  end

  describe ".reset!" do
    # Forgets the cursor, so the walk re-derives its anchor from the oldest row
    # held — which after a run includes whatever that run brought back.
    it "drops the cursor and re-anchors on the oldest row" do
      transaction("TRN-A", anchor)
      requests = stub_fetch(created: 1)
      described_class.call

      described_class.reset!
      expect(described_class.state[:cursor]).to be_nil

      oldest = BankTransaction.minimum(:posted_at)
      described_class.call
      expect(requests.second[:end_date].to_date).to eq((oldest + 3.days).to_date)
    end

    it "clears a finished walk so it can run again" do
      transaction("TRN-A", anchor)
      stub_fetch(created: 0)
      3.times { described_class.call }
      expect(described_class.call.status).to eq(:done)

      described_class.reset!

      expect(described_class.call.status).to eq(:fetched)
    end
  end
end
