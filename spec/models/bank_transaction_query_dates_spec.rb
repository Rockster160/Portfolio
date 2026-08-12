require "rails_helper"

# Every date form the banking page's search hint advertises. The hint is the
# only documentation there is, so a change in how dates parse should fail here
# rather than quietly make the examples wrong.
RSpec.describe BankTransaction, ".query" do
  let!(:account) {
    BankAccount.create!(
      simplefin_id: "ACT-1", name: "PREMIER PLUS CKG (2363)",
      last4: "2363", kind: :checking
    )
  }

  def row(id, at)
    BankTransaction.create!(
      simplefin_id: id, bank_account: account,
      posted_at: at, transacted_at: at, amount_cents: -1_000
    )
  end

  def found(query)
    BankTransaction.query(query).pluck(:simplefin_id).sort
  end

  # Dates parse in the user's zone, so the fixtures have to be built there too
  # or a midday UTC row lands on the previous day.
  around { |example| User.timezone { example.run } }

  before do
    row("JUL01", Time.zone.local(2026, 7, 1, 12))
    row("JUL15", Time.zone.local(2026, 7, 15, 12))
    row("AUG02", Time.zone.local(2026, 8, 2, 12))
    row("Y2025", Time.zone.local(2025, 3, 9, 12))
  end

  it "matches a single day" do
    expect(found("timestamp:2026-07-01")).to eq(["JUL01"])
  end

  it "matches a whole month from a year-month" do
    expect(found("timestamp:2026-07")).to eq(["JUL01", "JUL15"])
  end

  it "matches a whole year from a bare year" do
    expect(found("timestamp:2026")).to eq(["AUG02", "JUL01", "JUL15"])
  end

  # Two digits are read as month-day, not year-month — the year is assumed.
  it "assumes the current year for a month-day" do
    travel_to(Time.zone.local(2026, 12, 1)) do
      expect(found("timestamp:7-15")).to eq(["JUL15"])
    end
  end

  it "takes a range as two terms" do
    expect(found("timestamp>=2026-07-01 timestamp<2026-08-01")).to eq(["JUL01", "JUL15"])
  end

  it "negates with a leading dash" do
    expect(found("-timestamp:2026-07")).to eq(["AUG02", "Y2025"])
  end

  # The gotcha the hint calls out: a bare `>` steps over the entire unit named,
  # so `>2026-07-01` starts on the 2nd rather than at midnight on the 1st.
  it "excludes the whole named unit on a bare greater-than" do
    expect(found("timestamp>2026-07-01")).to eq(["AUG02", "JUL15"])
    expect(found("timestamp>=2026-07-01")).to eq(["AUG02", "JUL01", "JUL15"])
  end

  it "still exposes posted_at and transacted_at for the distinction" do
    expect(found("transacted_at:2026-07")).to eq(["JUL01", "JUL15"])
    expect(found("posted_at:2026-07")).to eq(["JUL01", "JUL15"])
  end

  # The whole reason `timestamp` is its own column: on 83% of real rows the
  # charge cleared on a different day from when it was made, and the table
  # shows the day it was made. Searching the displayed date has to find it.
  it "searches the date the table displays, not the date it cleared" do
    made = Time.zone.local(2026, 6, 28, 12)
    cleared = Time.zone.local(2026, 7, 2, 12)
    BankTransaction.create!(
      simplefin_id: "LAGGED", bank_account: account,
      transacted_at: made, posted_at: cleared, amount_cents: -1_000
    )

    expect(found("timestamp:2026-06-28")).to eq(["LAGGED"])
    expect(found("timestamp:2026-07-02")).not_to include("LAGGED")
    expect(found("posted_at:2026-07-02")).to eq(["LAGGED"])
  end

  # Documented as unsupported rather than left to be discovered: the tokenizer
  # splits fields on `:`, so a clock time is not a value it can ever receive.
  it "does not support a time of day" do
    expect(found("timestamp>2026-07-01T18:00")).to be_empty
  end

  # A bank reporting a DATE with no clock time sends epoch midnight UTC, which
  # Mountain reads as 6pm the previous day. 149 of 458 real rows.
  describe "a date-only row" do
    let(:date_only) {
      BankTransaction.create!(
        simplefin_id: "DATEONLY", bank_account: account, amount_cents: -1_000,
        posted_at: Time.utc(2026, 5, 13), transacted_at: Time.utc(2026, 5, 13)
      )
    }

    it "lands on the calendar day the bank named" do
      expect(date_only.occurred_local.to_date).to eq(Date.new(2026, 5, 13))
    end

    it "is found by the date the bank named, and not by the day before" do
      date_only
      expect(found("timestamp:2026-05-13")).to eq(["DATEONLY"])
      expect(found("timestamp:2026-05-12")).to be_empty
    end

    it "reports no clock time, so nothing invents one" do
      expect(date_only.occurred_time_known?).to be(false)
    end

    # The raw bank values are left alone. This column is the interpreted one,
    # which is the only reason it is safe to interpret.
    it "leaves posted_at and transacted_at untouched" do
      expect(date_only.posted_at).to eq(Time.utc(2026, 5, 13))
      expect(date_only.transacted_at).to eq(Time.utc(2026, 5, 13))
    end

    it "leaves a row that does carry a time exactly where it was" do
      timed = BankTransaction.create!(
        simplefin_id: "TIMED", bank_account: account, amount_cents: -1_000,
        posted_at: Time.utc(2026, 5, 13, 22, 31), transacted_at: Time.utc(2026, 5, 13, 22, 31)
      )

      expect(timed.occurred_at).to eq(Time.utc(2026, 5, 13, 22, 31))
      expect(timed.occurred_time_known?).to be(true)
    end

    # Denver is UTC-7 in winter and UTC-6 in summer; a fixed offset would move
    # half the year onto the wrong day.
    it "uses the offset in force on that date, not a fixed one" do
      winter = BankTransaction.create!(
        simplefin_id: "WINTER", bank_account: account, amount_cents: -1_000,
        posted_at: Time.utc(2026, 1, 14), transacted_at: Time.utc(2026, 1, 14)
      )

      expect(winter.occurred_at).to eq(Time.utc(2026, 1, 14, 7))
      expect(date_only.occurred_at).to eq(Time.utc(2026, 5, 13, 6))
    end
  end

  # posted_at and occurred_at are a different day on 83% of real rows, so
  # sorting on the wrong one puts the list visibly out of order against the
  # dates printed beside it.
  describe ".recent_first" do
    it "orders by when the purchase happened, not when it cleared" do
      BankTransaction.create!(
        simplefin_id: "MADE-LATER", bank_account: account, amount_cents: -100,
        transacted_at: Time.zone.local(2026, 7, 20, 12),
        posted_at:     Time.zone.local(2026, 7, 21, 12)
      )
      BankTransaction.create!(
        simplefin_id: "CLEARED-LATER", bank_account: account, amount_cents: -100,
        transacted_at: Time.zone.local(2026, 7, 21, 12),
        posted_at:     Time.zone.local(2026, 7, 25, 12)
      )

      ordered = BankTransaction.recent_first.pluck(:simplefin_id)
      expect(ordered.index("CLEARED-LATER")).to be < ordered.index("MADE-LATER")
    end

    # A third of rows carry no clock time and land on the same instant.
    # Without a tiebreaker, which of them appears on page 1 versus page 2 is
    # undefined and can differ between requests.
    it "breaks a tie deterministically" do
      same = Time.zone.local(2026, 7, 20)
      3.times { |i| row("TIE-#{i}", same) }

      first = BankTransaction.recent_first.pluck(:simplefin_id)
      second = BankTransaction.recent_first.pluck(:simplefin_id)
      expect(first).to eq(second)
    end
  end
end
