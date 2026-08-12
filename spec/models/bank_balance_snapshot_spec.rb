require "rails_helper"

# `bank_accounts.balance_cents` is overwritten on every sync. These rows are
# the only record that a past existed, and unlike transactions they cannot be
# fetched back from the Bridge later.
RSpec.describe BankBalanceSnapshot do
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "ACT-1", name: "PREMIER PLUS CKG (2363)", kind: :checking,
      balance_cents: 1_832_024, available_balance_cents: 1_800_000,
      balance_date: Time.utc(2026, 8, 12, 4)
    )
  }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "ACT-2", name: "AMZ Prime (7283)", kind: :credit,
      balance_cents: -198_853
    )
  }

  describe ".capture!" do
    it "records where the account stood" do
      snapshot = described_class.capture!(checking)

      expect(snapshot.balance_cents).to eq(1_832_024)
      expect(snapshot.available_balance_cents).to eq(1_800_000)
      expect(snapshot.balance_date).to eq(Time.utc(2026, 8, 12, 4))
    end

    # Fourteen syncs a day all write the same row. The day is worth what it
    # ended at, not what it was at the first poll.
    it "keeps one row per account per day, last write winning" do
      described_class.capture!(checking)
      checking.update!(balance_cents: 900_000)

      expect { described_class.capture!(checking) }.not_to change(described_class, :count)
      expect(described_class.sole.balance_cents).to eq(900_000)
    end

    it "keeps a separate row per account" do
      described_class.capture!(checking)
      described_class.capture!(card)

      expect(described_class.count).to eq(2)
    end

    it "keeps a separate row per day" do
      described_class.capture!(checking, on: Date.new(2026, 8, 11))
      described_class.capture!(checking, on: Date.new(2026, 8, 12))

      expect(described_class.count).to eq(2)
    end

    # A day is either recorded or it is not. A row that guessed would be
    # indistinguishable later from one that knew.
    it "writes nothing for an account with no balance yet" do
      blank = BankAccount.create!(simplefin_id: "ACT-3", name: "New (0001)", balance_cents: nil)

      expect(described_class.capture!(blank)).to be_nil
      expect(described_class.count).to be_zero
    end

    # A sync at 6pm Mountain is already the next day in UTC. Filing it under
    # tomorrow would leave a hole today and two rows tomorrow.
    it "files under the local day, not the UTC one" do
      travel_to(Time.utc(2026, 8, 13, 1)) do # 7pm Aug 12 in Mountain
        expect(described_class.capture!(checking).captured_on).to eq(Date.new(2026, 8, 12))
      end
    end
  end

  describe ".totals_by_day" do
    before do
      described_class.capture!(checking, on: Date.new(2026, 8, 11))
      described_class.capture!(card, on: Date.new(2026, 8, 11))
    end

    it "sums the accounts it was given" do
      expect(described_class.totals_by_day([checking, card])).to eq(
        Date.new(2026, 8, 11) => 1_633_171,
      )
    end

    it "takes a relation as readily as an array" do
      expect(described_class.totals_by_day(BankAccount.all).values).to eq([1_633_171])
    end

    # A day where one account is missing would otherwise read as a balance that
    # fell off a cliff, which is worse than having no point to plot.
    it "omits a day that is missing one of the accounts" do
      described_class.capture!(checking, on: Date.new(2026, 8, 12))

      expect(described_class.totals_by_day([checking, card]).keys).to eq([Date.new(2026, 8, 11)])
    end

    it "is empty rather than wrong when given no accounts" do
      expect(described_class.totals_by_day([])).to eq({})
    end
  end

  describe "captured through a sync" do
    it "writes a row for every account the payload carried" do
      payload = {
        "accounts" => [
          {
            "id"                => "ACT-1",
            "name"              => "PREMIER PLUS CKG (2363)",
            "balance"           => "18320.24",
            "available-balance" => "18000.00",
            "balance-date"      => Time.utc(2026, 8, 12, 4).to_i,
            "transactions"      => [],
          },
        ],
      }

      expect { SimpleFin::Sync.call(payload) }.to change(described_class, :count).by(1)
      expect(described_class.sole.balance_cents).to eq(1_832_024)
    end
  end
end
