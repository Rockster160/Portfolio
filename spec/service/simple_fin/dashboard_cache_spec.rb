require "rails_helper"

# The home cell reads `Global.get_cache("bank", "amount")` via Jil task 439.
# Nothing wrote that key, which is why the dashboard showed "?".
RSpec.describe SimpleFin::DashboardCache do
  let(:user) { User.me }

  def account(kind:, cents:, id: "ACT-0001", name: "PREMIER PLUS CKG (2363)")
    BankAccount.create!(simplefin_id: id, name: name, kind: kind, balance_cents: cents)
  end

  describe ".refresh!" do
    it "publishes the checking balance into the bank cache" do
      account(kind: :checking, cents: 1_832_024)

      described_class.refresh!(user: user)

      expect(user.caches.dig(:bank, :amount)).to eq("18320.24")
    end

    it "writes a value home.js can divide by 1000" do
      account(kind: :checking, cents: 1_832_024)
      described_class.refresh!(user: user)

      raw = user.caches.dig(:bank, :amount)
      expect((raw.to_f / 1000).floor).to eq(18)
    end

    # Better a "?" than a mortgage balance behind a bank icon.
    it "writes nothing when no checking account is designated" do
      account(kind: :credit, cents: -198_853)

      expect(described_class.refresh!(user: user)).to be_nil
      expect(user.caches.dig(:bank, :amount)).to be_nil
    end

    it "writes nothing when there are no accounts at all" do
      expect(described_class.refresh!(user: user)).to be_nil
    end

    it "ignores a checking account with no balance yet" do
      account(kind: :checking, cents: nil)

      expect(described_class.refresh!(user: user)).to be_nil
    end

    it "updates the value on a later run" do
      acct = account(kind: :checking, cents: 1_832_024)
      described_class.refresh!(user: user)

      acct.update!(balance_cents: 900_000)
      described_class.refresh!(user: user)

      expect(user.caches.dig(:bank, :amount)).to eq("9000.0")
    end
  end

  describe ".primary" do
    it "picks the checking account" do
      account(kind: :credit, cents: -1, id: "ACT-0002", name: "AMZ Prime (7283)")
      main = account(kind: :checking, cents: 100)

      expect(described_class.primary).to eq(main)
    end

    it "breaks a tie on lowest id so the value cannot flip between syncs" do
      first = account(kind: :checking, cents: 100)
      account(kind: :checking, cents: 200, id: "ACT-0002", name: "Second CKG (9999)")

      expect(described_class.primary).to eq(first)
    end
  end
end
