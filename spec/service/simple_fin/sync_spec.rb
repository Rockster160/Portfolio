require "rails_helper"

# Built against a real (redacted) v2 payload: four Chase accounts where the
# card and the mortgage carry negative balances and a placeholder
# "available-balance" of "0.00".
RSpec.describe SimpleFin::Sync do
  def account_data(overrides={})
    {
      "id"                => "ACT-0001",
      "name"              => "PREMIER PLUS CKG (2363)",
      "currency"          => "USD",
      "balance"           => "18320.24",
      "available-balance" => "18320.24",
      "balance-date"      => 1_786_418_154,
      "transactions"      => [],
      "conn_id"           => "MX-MBR-0001",
    }.merge(overrides)
  end

  def transaction_data(overrides={})
    {
      "id"            => "TRN-0001",
      "posted"        => 1_786_104_000,
      "amount"        => "-238.42",
      "description"   => "Lowes SYF PAYMNT 798192445915919 WEB ID: 9069872103",
      "payee"         => "Lowe's Credit Card by Synchrony",
      "memo"          => "",
      "transacted_at" => 1_785_931_200,
      "mcc"           => nil,
    }.merge(overrides)
  end

  def payload(accounts, errlist: [])
    { "errlist" => errlist, "accounts" => accounts }
  end

  describe ".call" do
    it "creates an account from the payload" do
      described_class.call(payload([account_data]))

      account = BankAccount.find_by(simplefin_id: "ACT-0001")
      expect(account.name).to eq("PREMIER PLUS CKG (2363)")
      expect(account.conn_id).to eq("MX-MBR-0001")
      expect(account.currency).to eq("USD")
      expect(account.balance_cents).to eq(1_832_024)
      expect(account.balance_date).to eq(Time.at(1_786_418_154).utc)
      expect(account.last_synced_at).to be_present
    end

    it "converts money via BigDecimal, not float" do
      described_class.call(payload([account_data("balance" => "-337183.97")]))

      expect(BankAccount.last.balance_cents).to eq(-33_718_397)
    end

    it "keeps debt balances negative" do
      described_class.call(payload([account_data("balance" => "-1988.53")]))

      expect(BankAccount.last.balance_cents).to eq(-198_853)
    end

    it "leaves a newly-linked account unclassified rather than guessing" do
      described_class.call(payload([account_data("name" => "MORTGAGE LOAN (7153)")]))

      expect(BankAccount.last).to be_unknown
    end

    it "does not clobber a kind that was set by hand" do
      described_class.call(payload([account_data]))
      BankAccount.last.update!(kind: :checking)

      described_class.call(payload([account_data("balance" => "20000.00")]))

      account = BankAccount.last
      expect(account).to be_checking
      expect(account.balance_cents).to eq(2_000_000)
    end

    it "updates in place on a resync instead of duplicating" do
      described_class.call(payload([account_data]))
      described_class.call(payload([account_data("balance" => "1.00")]))

      expect(BankAccount.count).to eq(1)
      expect(BankAccount.last.balance_cents).to eq(100)
    end

    it "stores balance_date verbatim so a stale upstream stays visibly stale" do
      stale = 1_786_000_000
      described_class.call(payload([account_data("balance-date" => stale)]))

      expect(BankAccount.last.balance_date).to eq(Time.at(stale).utc)
    end

    context "with transactions" do
      it "creates them against their account" do
        described_class.call(
          payload([account_data("transactions" => [transaction_data])]),
        )

        transaction = BankTransaction.find_by(simplefin_id: "TRN-0001")
        expect(transaction.bank_account.simplefin_id).to eq("ACT-0001")
        expect(transaction.amount_cents).to eq(-23_842)
        expect(transaction.payee).to eq("Lowe's Credit Card by Synchrony")
        expect(transaction.posted_at).to eq(Time.at(1_786_104_000).utc)
        expect(transaction.transacted_at).to eq(Time.at(1_785_931_200).utc)
        expect(transaction).not_to be_pending
      end

      it "updates rather than duplicating when a window overlaps" do
        described_class.call(payload([account_data("transactions" => [transaction_data])]))
        described_class.call(
          payload([account_data("transactions" => [transaction_data("amount" => "-999.99")])]),
        )

        expect(BankTransaction.count).to eq(1)
        expect(BankTransaction.last.amount_cents).to eq(-99_999)
      end

      it "records the pending flag when present" do
        described_class.call(
          payload([account_data("transactions" => [transaction_data("pending" => true)])]),
        )

        expect(BankTransaction.last).to be_pending
      end

      it "counts what it wrote" do
        rows = [transaction_data, transaction_data("id" => "TRN-0002")]
        result = described_class.call(payload([account_data("transactions" => rows)]))

        expect(result.transactions).to eq(2)
        expect(result.accounts).to eq(1)
      end
    end

    context "when the payload carries upstream errors" do
      let(:errlist) { [{ "id" => "err_1", "message" => "Chase needs reauthentication" }] }

      it "still stores the accounts that did come back" do
        result = described_class.call(payload([account_data], errlist: errlist))

        expect(BankAccount.count).to eq(1)
        expect(result).to be_errors
        expect(result.errors.first["message"]).to eq("Chase needs reauthentication")
      end

      it "logs them rather than failing silently" do
        expect(Rails.logger).to receive(:warn).with(/upstream error/)

        described_class.call(payload([account_data], errlist: errlist))
      end
    end

    it "tolerates a payload with no accounts" do
      result = described_class.call(payload([]))

      expect(result.accounts).to be_zero
      expect(result).not_to be_errors
    end
  end

  describe ".run!" do
    it "fetches through the client and folds the result" do
      allow(SimpleFin::Client).to receive(:accounts)
        .with(balances_only: true)
        .and_return(payload([account_data]))

      result = described_class.run!(balances_only: true)

      expect(result.accounts).to eq(1)
      expect(BankAccount.count).to eq(1)
    end
  end

  # The alert arrives first and the bank clears the same purchase up to four
  # days later. Both describe one transaction, and it must end up as one row.
  describe "merging with a Chase alert that got there first" do
    let(:posted) { 1_786_104_000 }
    let(:transacted) { 1_785_931_200 }

    def alert!
      event = ActionEvent.create!(
        user: User.me, name: "Transaction", timestamp: Time.at(transacted).utc,
        notes: "Deck boards",
        data: {
          amount: 238.42, account: "(...2363)", category: "home", merchant: "LOWES"
        }
      )
      SimpleFin::EventTransaction.sync(event)
    end

    before { described_class.call(payload([account_data])) } # lays down the account

    it "folds the bank's version into the row the alert made" do
      row = alert!

      described_class.call(payload([account_data("transactions" => [transaction_data])]))

      expect(BankTransaction.count).to eq(1)
      expect(row.reload.simplefin_id).to eq("TRN-0001")
    end

    it "keeps the category the alert was given" do
      alert!

      described_class.call(payload([account_data("transactions" => [transaction_data])]))

      expect(BankTransaction.first.category).to eq("home")
    end

    it "takes the bank's figures over the alert's" do
      alert!

      described_class.call(payload([account_data("transactions" => [transaction_data])]))

      row = BankTransaction.first
      expect(row.payee).to eq("Lowe's Credit Card by Synchrony")
      expect(row.posted_at).to eq(Time.at(posted).utc)
      expect(row.amount_cents).to eq(-23_842)
    end

    # A merge is not new history. The backfill reads `created` to decide
    # whether there is anything older left to fetch, and counting a row it
    # already held would keep the walk going against an empty window.
    it "does not count a merge as a row created" do
      alert!

      result = described_class.call(payload([account_data("transactions" => [transaction_data])]))

      expect(result.created).to be_zero
    end

    it "leaves an unrelated charge of a different size alone" do
      alert!

      described_class.call(
        payload([account_data("transactions" => [transaction_data("amount" => "-99.00")])]),
      )

      expect(BankTransaction.count).to eq(2)
    end
  end
end
