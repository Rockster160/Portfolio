require "rails_helper"

# Same tokenizer as ActionEvent. The scopes behind `account` / `category` are
# subqueries rather than joins because `stripped_sql` drops inner joins — these
# examples are what would catch that regressing.
RSpec.describe BankTransaction, ".query" do
  let(:user) { User.me }
  let!(:payday) {
    event = ActionEvent.create!(
      user: user, name: "Transaction", timestamp: 4.days.ago,
      data: { amount: 4370.70, account: "(...2363)", category: "pay check" }
    )
    BankTransaction.create!(
      simplefin_id: "T4", bank_account: checking, action_event: event,
      posted_at: 4.days.ago, amount_cents: 437_070, payee: "One Claim Payroll"
    )
  }
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "A1", name: "PREMIER PLUS CKG (2363)",
      last4: "2363", kind: :checking, friendly_name: "Main"
    )
  }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "A2", name: "AMZ Prime (7283)",
      last4: "7283", kind: :credit
    )
  }

  let!(:groceries) {
    event = ActionEvent.create!(
      user: user, name: "Transaction", timestamp: 3.days.ago,
      data: { amount: 82.10, account: "(...2363)", category: "groceries" }
    )
    BankTransaction.create!(
      simplefin_id: "T1", bank_account: checking, action_event: event,
      posted_at: 3.days.ago, amount_cents: -8210, payee: "Costco Wholesale",
      category: "groceries"
    )
  }
  let!(:coffee) {
    event = ActionEvent.create!(
      user: user, name: "Transaction", timestamp: 1.day.ago,
      data: { amount: 6.40, account: "(...7283)", category: "eat out" }
    )
    BankTransaction.create!(
      simplefin_id: "T2", bank_account: card, action_event: event,
      posted_at: 1.day.ago, amount_cents: -640, payee: "Dutch Bros",
      category: "eat out"
    )
  }
  let!(:orphan) {
    BankTransaction.create!(
      simplefin_id: "T3", bank_account: card, posted_at: 2.days.ago,
      amount_cents: -1500, payee: "Mystery Charge", pending: true
    )
  }

  def found(query) = described_class.query(query).to_a

  it "matches a payee substring" do
    expect(found("payee:costco")).to contain_exactly(groceries)
  end

  # Two rows that read identically on screen are the thing you most need to
  # tell apart — which feed each came from is what says whether they are a
  # duplicate or a genuine repeat charge.
  describe "#source_summary" do
    it "names the id and the SimpleFIN record for a bank row" do
      expect(orphan.source_summary).to include("##{orphan.id}", "SimpleFIN T3")
    end

    it "says so when a row exists only because an alert arrived" do
      row = BankTransaction.create!(
        bank_account: card, amount_cents: -100, transacted_at: 1.day.ago,
        action_event: ActionEvent.create!(
          user: user, name: "Transaction", timestamp: 1.day.ago,
          data: { amount: 1, account: "(...7283)", category: "fun" }
        )
      )

      expect(row.source_summary).to include("not yet in the bank feed", "alert #")
      expect(row.source_summary).not_to include("posted")
    end
  end

  it "matches a category" do
    expect(found("category:groceries")).to contain_exactly(groceries)
  end

  # The row that no alert covered is the one you most want to list, and an
  # ILIKE against NULL would never find it.
  it "lists what has no category at all" do
    expect(found("category:none")).to contain_exactly(orphan, payday)
  end

  it "matches an account by friendly name" do
    expect(found("account:Main")).to contain_exactly(groceries, payday)
  end

  it "matches an account by last four" do
    expect(found("account:7283")).to contain_exactly(coffee, orphan)
  end

  describe "amount" do
    # It is a plain column derived on save, not a generated one — production
    # is PostgreSQL 9.5. These two are what would catch it drifting.
    it "is derived on create" do
      expect(payday.reload.amount_abs).to eq(BigDecimal("4370.70"))
    end

    it "follows amount_cents on update, including a sign flip" do
      payday.update!(amount_cents: -1234)
      expect(payday.reload.amount_abs).to eq(BigDecimal("12.34"))
    end

    # Magnitude, in dollars. Sign is `direction:` — it deliberately is not part
    # of the number, because a leading `-` is the tokenizer's negation prefix.
    it "is absolute, so a spend and a deposit of the same size both match" do
      big_spend = BankTransaction.create!(
        simplefin_id: "T5", bank_account: checking,
        posted_at: 5.days.ago, amount_cents: -437_070, payee: "Wire Out"
      )

      # The point is that a -437070 row answers a positive threshold at all.
      expect(found("amount>4000")).to contain_exactly(payday, big_spend)
    end

    it "compares with > and <" do
      expect(found("amount>100")).to contain_exactly(payday)
      expect(found("amount<10")).to contain_exactly(coffee)
    end

    it "handles a decimal threshold" do
      expect(found("amount>82")).to contain_exactly(groceries, payday)
    end
  end

  describe "direction" do
    it "selects deposits" do
      expect(found("direction:deposit")).to contain_exactly(payday)
    end

    it "selects withdrawals" do
      expect(found("direction:withdrawal")).to contain_exactly(groceries, coffee, orphan)
    end

    it "accepts the shorter words" do
      expect(found("direction:in")).to contain_exactly(payday)
      expect(found("direction:out")).to contain_exactly(groceries, coffee, orphan)
    end

    it "combines with an absolute amount to recover signed filtering" do
      expect(found("amount>100 direction:out")).to be_empty
      expect(found("amount>100 direction:in")).to contain_exactly(payday)
    end

    # A term the user believes narrowed the list must not quietly match all.
    it "matches nothing when the value is meaningless" do
      expect(found("direction:sideways")).to be_empty
    end
  end

  # Asserted well clear of the boundary in both directions. Whether `>` on a
  # bare date resolves to the start or the end of that day is the tokenizer's
  # business, and pinning it here would test that rather than this.
  it "filters on a date range" do
    expect(found("posted_at>#{10.days.ago.to_date}"))
      .to contain_exactly(groceries, coffee, orphan, payday)
    expect(found("posted_at<#{10.days.ago.to_date}")).to be_empty
  end

  it "filters on pending" do
    expect(found("pending:true")).to contain_exactly(orphan)
  end

  it "filters on whether a row is linked" do
    expect(found("linked:false")).to contain_exactly(orphan)
    expect(found("linked:true")).to contain_exactly(groceries, coffee, payday)
  end

  it "combines terms" do
    expect(found("account:7283 payee:dutch")).to contain_exactly(coffee)
  end

  it "negates" do
    expect(found("-payee:costco")).to contain_exactly(coffee, orphan, payday)
  end

  it "ORs" do
    expect(found("payee:costco OR payee:dutch")).to contain_exactly(groceries, coffee)
  end

  # An uncategorized row has no category to match, rather than matching all.
  it "excludes unlinked rows from a category filter" do
    expect(found("category:eat")).not_to include(orphan)
  end
end
