require "rails_helper"

RSpec.describe BankTransaction, ".query" do
  # Same tokenizer as ActionEvent. The scopes behind `account` / `category` are
  # subqueries rather than joins because `stripped_sql` drops inner joins — these
  # examples are what would catch that regressing.
  describe "query" do
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

    # The matching surface as a table: query in, rows out. Every line here was
    # its own example, and each one rebuilt the same four transactions, three
    # action events and two accounts to ask a single question of them. A
    # failure still names the query and what came back instead.
    def expect_matches(table)
      wrong = table.filter_map { |query, names|
        want = names.map { |name| send(name) }
        got  = found(query)
        next if got.map(&:id).sort == want.map(&:id).sort

        "#{query} → #{got.map(&:payee).sort}, expected #{want.map(&:payee).sort}"
      }

      expect(wrong).to eq([])
    end

    it "matches on payee, category and account" do
      expect_matches(
        "payee:costco"       => %i[groceries],
        "category:groceries" => %i[groceries],
        # The row that no alert covered is the one you most want to list, and an
        # ILIKE against NULL would never find it.
        "category:none"      => %i[orphan payday],
        # ...and an uncategorized row has no category to match, rather than
        # matching every filter.
        "category:eat"       => %i[coffee],
        "account:Main"       => %i[groceries payday],
        "account:7283"       => %i[coffee orphan],
      )
    end

    it "selects by direction in both spellings, and narrows rather than matching all" do
      expect_matches(
        "direction:deposit"        => %i[payday],
        "direction:withdrawal"     => %i[groceries coffee orphan],
        "direction:in"             => %i[payday],
        "direction:out"            => %i[groceries coffee orphan],
        # Absolute amount plus a direction is how signed filtering is recovered.
        "amount>100 direction:out" => [],
        "amount>100 direction:in"  => %i[payday],
        # A term the user believes narrowed the list must not quietly match all.
        "direction:sideways"       => [],
      )
    end

    it "combines, negates, ORs, and filters on the row's own flags" do
      expect_matches(
        "account:7283 payee:dutch"    => %i[coffee],
        "-payee:costco"               => %i[coffee orphan payday],
        "payee:costco OR payee:dutch" => %i[groceries coffee],
        "pending:true"                => %i[orphan],
        "linked:false"                => %i[orphan],
        "linked:true"                 => %i[groceries coffee payday],
      )
    end

    # Asserted well clear of the boundary in both directions. Whether `>` on a
    # bare date resolves to the start or the end of that day is the tokenizer's
    # business, and pinning it here would test that rather than this.
    it "filters on a date range" do
      expect_matches(
        "posted_at>#{10.days.ago.to_date}" => %i[groceries coffee orphan payday],
        "posted_at<#{10.days.ago.to_date}" => [],
      )
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
      it "compares with > and <, and takes a decimal threshold" do
        expect_matches(
          "amount>100" => %i[payday],
          "amount<10"  => %i[coffee],
          "amount>82"  => %i[groceries payday],
        )
      end
    end

    # Two rows that read the same on screen are what you most need to tell apart.
    # Record ids only, in the form you would type to go and find one.
    describe "#source_summary" do
      it "names the bank transaction" do
        expect(orphan.source_summary).to eq("BankTransaction##{orphan.id}")
      end

      it "names the event and the email behind an alert-sourced row" do
        event = ActionEvent.create!(
          user: user, name: "Transaction", timestamp: 1.day.ago,
          data: { amount: 1, account: "(...7283)", category: "fun", email_id: 51_450 }
        )
        row = BankTransaction.create!(
          bank_account: card, amount_cents: -100, transacted_at: 1.day.ago, action_event: event,
        )

        expect(row.source_summary).to(
          eq("BankTransaction##{row.id} ActionEvent##{event.id} Email#51450"),
        )
      end

      # A 36-character UUID identifies the row already being looked at, and the
      # posted date is in the table.
      it "says nothing about the SimpleFIN id or the posted date" do
        expect(orphan.source_summary).not_to include("SimpleFIN", "T3", "posted")
      end
    end
  end

  # Every date form the banking page's search hint advertises. The hint is the
  # only documentation there is, so a change in how dates parse should fail here
  # rather than quietly make the examples wrong.
  describe "dates" do
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

    # Every form in one pass over one set of rows. These were nine examples,
    # and each rebuilt the account and the four dated rows to run one query.
    def expect_dates(table)
      wrong = table.filter_map { |query, ids|
        got = found(query)
        next if got == ids.sort

        "#{query} → #{got}, expected #{ids.sort}"
      }

      expect(wrong).to eq([])
    end

    it "reads every date form the hint advertises" do
      expect_dates(
        "timestamp:2026-07-01" => %w[JUL01],
        "timestamp:2026-07"    => %w[JUL01 JUL15],
        "timestamp:2026"       => %w[AUG02 JUL01 JUL15],
        "timestamp>=2026-07-01 timestamp<2026-08-01" => %w[JUL01 JUL15],
        "-timestamp:2026-07"   => %w[AUG02 Y2025],
        # The gotcha the hint calls out: a bare `>` steps over the entire unit
        # named, so `>2026-07-01` starts on the 2nd rather than at midnight on
        # the 1st.
        "timestamp>2026-07-01"  => %w[AUG02 JUL15],
        "timestamp>=2026-07-01" => %w[AUG02 JUL01 JUL15],
        # Both underlying columns stay reachable, for the rows where they differ.
        "transacted_at:2026-07" => %w[JUL01 JUL15],
        "posted_at:2026-07"     => %w[JUL01 JUL15],
        # Documented as unsupported rather than left to be discovered: the
        # tokenizer splits fields on `:`, so a clock time is not a value it can
        # ever receive.
        "timestamp>2026-07-01T18:00" => [],
      )
    end

    # Two digits are read as month-day, not year-month — the year is assumed.
    it "assumes the current year for a month-day" do
      travel_to(Time.zone.local(2026, 12, 1)) do
        expect(found("timestamp:7-15")).to eq(["JUL15"])
      end
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
end
