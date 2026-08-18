require "rails_helper"

RSpec.describe BankChart do
  let!(:account) {
    BankAccount.create!(
      simplefin_id: "ACT-0001", name: "PREMIER PLUS CKG (2363)", last4: "2363",
      kind: :checking, balance_cents: 1
    )
  }

  def charge(on:, cents:, category:, id: nil)
    User.timezone {
      at = Time.zone.parse("#{on} 12:00")
      BankTransaction.create!(
        simplefin_id: id || "TRN-#{SecureRandom.hex(4)}", bank_account: account,
        posted_at: at, transacted_at: at, amount_cents: cents, payee: "Test",
        category: category
      )
    }
  end

  def payload(bucket: :month, from: nil, to: nil, scope: BankTransaction.all)
    described_class.new(scope, bucket: bucket, from: from, to: to).call
  end

  def series(result, label)
    result[:datasets].detect { |ds| ds[:label] == label }
  end

  describe "the two stacks" do
    before do
      charge(on: "2026-07-04", cents: -5_000, category: "groceries")
      charge(on: "2026-07-06", cents: 250_000, category: "pay check")
    end

    # Money out and money in stand SIDE BY SIDE per bucket rather than one
    # column crossing zero, so each reads as a whole on its own.
    it "puts spending and income in their own stacks" do
      result = payload

      expect(series(result, "Groceries")[:stack]).to eq("out")
      expect(series(result, "Pay Check")[:stack]).to eq("in")
    end

    # Both grow upward on the one shared scale — never a second or mirrored axis.
    it "plots magnitudes, so both arms compare directly" do
      result = payload

      expect(series(result, "Groceries")[:data]).to eq([50.0])
      expect(series(result, "Pay Check")[:data]).to eq([2500.0])
    end

    it "draws each category in the color the rest of the page uses" do
      expect(series(payload, "Groceries")[:color]).to eq(TransactionCategory.color(:groceries))
    end
  end

  # A month holding a single refund would otherwise move the category to the
  # income side for that column alone, and it would appear in both stacks.
  it "decides a category's stack from its whole-window total, not one bucket" do
    charge(on: "2026-06-10", cents: -40_000, category: "home")
    charge(on: "2026-07-10", cents: 3_000, category: "home")

    home = series(payload, "Home")

    expect(home[:stack]).to eq("out")
    expect(home[:data]).to eq([400.0, 30.0])
  end

  # A month with no spending is a fact about the month. Dropping it would put
  # two non-adjacent columns side by side and make the gap invisible.
  it "fills the buckets nothing landed in" do
    charge(on: "2026-05-02", cents: -1_000, category: "fun")
    charge(on: "2026-08-02", cents: -2_000, category: "fun")

    result = payload

    expect(result[:labels]).to eq(["May 2026", "Jun 2026", "Jul 2026", "Aug 2026"])
    expect(series(result, "Fun")[:data]).to eq([10.0, 0.0, 0.0, 20.0])
  end

  # Asking for a year and seeing an axis that stops at the last purchase hides
  # that the rest of the year was empty.
  it "spans the dates the search names, not just the data" do
    charge(on: "2026-07-15", cents: -1_000, category: "fun")

    result = payload(from: Date.new(2026, 5, 1), to: Date.new(2026, 8, 31))

    expect(result[:labels]).to eq(["May 2026", "Jun 2026", "Jul 2026", "Aug 2026"])
  end

  it "orders the biggest category first" do
    charge(on: "2026-07-04", cents: -500, category: "fun")
    charge(on: "2026-07-05", cents: -90_000, category: "mortgage")

    expect(payload[:datasets].pluck(:label)).to eq(["Mortgage", "Fun"])
  end

  it "names a row with no category rather than dropping it" do
    charge(on: "2026-07-04", cents: -500, category: nil)

    expect(payload[:datasets].pluck(:label)).to eq(["(none)"])
  end

  describe "the labels" do
    it "carries the year on a daily axis that crosses one" do
      charge(on: "2025-12-30", cents: -100, category: "fun")
      charge(on: "2026-01-02", cents: -100, category: "fun")

      expect(payload(bucket: :day)[:labels].first).to eq("Dec 30, 2025")
    end

    # The same year on every tick of a one-week view is noise.
    it "leaves the year off when the whole axis sits inside one" do
      charge(on: "2026-07-01", cents: -100, category: "fun")
      charge(on: "2026-07-03", cents: -100, category: "fun")

      expect(payload(bucket: :day)[:labels]).to eq(["Jul 1", "Jul 2", "Jul 3"])
    end
  end

  # It refuses and says so rather than quietly coarsening the bucket, which
  # would answer a question nobody asked.
  it "refuses a range too wide to draw at the chosen bucket" do
    charge(on: "2020-01-01", cents: -100, category: "fun")
    charge(on: "2026-01-01", cents: -100, category: "fun")

    result = payload(bucket: :day)

    expect(result[:datasets]).to be_empty
    expect(result[:message]).to include("pick a bigger bucket")
  end

  it "says there is nothing to chart when the search matched nothing" do
    result = payload(scope: BankTransaction.none)

    expect(result[:datasets]).to be_empty
    expect(result[:message]).to eq("Nothing to chart.")
  end

  it "charts only what the given scope matched" do
    charge(on: "2026-07-04", cents: -5_000, category: "groceries")
    charge(on: "2026-07-05", cents: -6_000, category: "fun")

    result = payload(scope: BankTransaction.where(category: "fun"))

    expect(result[:datasets].pluck(:label)).to eq(["Fun"])
  end

  it "falls back to the default bucket when handed one it does not have" do
    charge(on: "2026-07-04", cents: -5_000, category: "groceries")

    expect(payload(bucket: :fortnight)[:bucket]).to eq(:month)
  end
end
