require "rails_helper"

RSpec.describe BankStatementImporter do
  let!(:account) {
    BankAccount.create!(name: "MACU Checking (7937)", last4: "7937")
  }

  # The header row of a real MACU export, in the order the file ships it.
  def headers
    [
      "Transaction ID",
      "Posting Date",
      "Effective Date",
      "Transaction Type",
      "Amount",
      "Check Number",
      "Reference Number",
      "Description",
      "Transaction Category",
      "Type",
      "Balance",
      "Memo",
      "Extended Description",
    ]
  end

  def row(
    id:,
    date: "8/20/2026",
    amount: "-27.71000",
    description: "Tesla",
    category: "Insurance",
    balance: "4391.24000",
    extended: nil,
    type: "Debit")
    {
      "Transaction ID"       => id,
      "Posting Date"         => date,
      "Effective Date"       => "",
      "Transaction Type"     => type,
      "Amount"               => amount,
      "Check Number"         => "",
      "Reference Number"     => "4273782706",
      "Description"          => description,
      "Transaction Category" => category,
      "Type"                 => "Retail ACH",
      "Balance"              => balance,
      "Memo"                 => "",
      "Extended Description" => extended || description,
    }
  end

  def csv_for(*rows, columns: headers)
    CSV.generate { |out|
      out << columns
      rows.each { |data| out << columns.map { |header| data[header] } }
    }
  end

  # The mapping the upload screen would have proposed and the person accepted.
  def mapping
    described_class.guess(headers)
  end

  def import(*rows, into: account, map: nil, categories: {}, source: "macu")
    described_class.call(
      csv_for(*rows),
      account: into, mapping: map || mapping, categories: categories,
      source: source, filename: "ExportedTransactions.csv"
    )
  end

  describe ".guess" do
    # The whole reason a mapping screen exists is that these guesses are
    # proposals. They still have to be right on a file we have actually seen.
    # `payee` gets the plain "Description" column, left over once the extended
    # one is claimed — MACU cleans the merchant name into it on card rows.
    it "reads a real MACU header row" do
      expected = {
        identifier:  "Transaction ID",
        date:        "Posting Date",
        amount:      "Amount",
        balance:     "Balance",
        category:    "Transaction Category",
        description: "Extended Description",
        payee:       "Description",
      }

      expect(described_class.guess(headers)).to(eq(expected))
    end

    # MACU ships both "Posting Date" and "Effective Date", and both
    # "Description" and "Extended Description". A bare /date/ or /description/
    # takes whichever is leftmost, which is a coin flip.
    it "prefers the specific header when a file carries two that could match" do
      guess = described_class.guess(headers)

      expect(guess[:date]).to(eq("Posting Date"))
      expect(guess[:description]).to(eq("Extended Description"))
    end

    it "never gives two fields the same column" do
      guess = described_class.guess(headers)

      expect(guess.values).to(eq(guess.values.uniq))
    end

    it "reads a differently-named export" do
      guess = described_class.guess(["Details", "Posted Date", "Amount", "Payee", "Account Name"])

      expect(guess[:date]).to(eq("Posted Date"))
      expect(guess[:description]).to(eq("Details"))
      expect(guess[:payee]).to(eq("Payee"))
      expect(guess[:account]).to(eq("Account Name"))
    end

    it "leaves a field out rather than reaching for an unrelated column" do
      expect(described_class.guess(["Amount", "When"])).not_to(have_key(:payee))
    end
  end

  describe ".inspect_file" do
    it "reports the columns, a proposed mapping, and the row count" do
      result = described_class.inspect_file(csv_for(row(id: "A1"), row(id: "A2")))

      expect(result[:headers]).to(eq(headers))
      expect(result[:mapping][:identifier]).to(eq("Transaction ID"))
      expect(result[:rows]).to(eq(2))
    end

    it "lists the distinct category values with a suggestion for each" do
      result = described_class.inspect_file(
        csv_for(
          row(id: "A1", category: "Insurance"),
          row(id: "A2", category: "Groceries"),
          row(id: "A3", category: "Insurance"),
          row(id: "A4", category: "Online Services"),
        ),
      )

      # "Online Services" gets no suggestion: MACU files a mortgage under it,
      # so the merchant rules are a better answer than any fixed mapping.
      expected = {
        "Groceries"       => :groceries,
        "Insurance"       => :insurance,
        "Online Services" => nil,
      }

      expect(result[:categories]).to(eq(expected))
    end

    it "recognizes a file it has seen before so the dedupe key stays stable" do
      result = described_class.inspect_file(csv_for(row(id: "A1")), filename: "Whatever.csv")

      expect(result[:source]).to(eq("macu"))
    end

    it "falls back to the filename for a file it does not recognize" do
      csv = csv_for({ "When" => "1/1/2026", "How much" => "-1" }, columns: ["When", "How much"])
      result = described_class.inspect_file(csv, filename: "Ally Checking Export.csv")

      expect(result[:source]).to(eq("ally-checking-export"))
    end

    it "writes nothing" do
      expect { described_class.inspect_file(csv_for(row(id: "A1"))) }.not_to(
        change(BankTransaction, :count),
      )
    end
  end

  describe "reading a file" do
    it "creates a row per line, signed as the file signs it" do
      result = import(
        row(id: "A1", amount: "-27.71000"),
        row(id: "A2", amount: "410.51000", type: "Credit"),
      )

      expect(result.rows).to(eq(2))
      expect(result.created).to(eq(2))
      expect(BankTransaction.pluck(:amount_cents)).to(contain_exactly(-2_771, 41_051))
    end

    it "namespaces the dedupe key by source so two institutions cannot collide" do
      import(row(id: "A1"))

      expect(BankTransaction.first.upstream_id).to(eq("macu:A1"))
    end

    it "records which upload put the row there" do
      import(row(id: "A1"))
      provenance = BankTransaction.first.metadata["import"]

      expect(provenance["source"]).to(eq("macu"))
      expect(provenance["file"]).to(eq("ExportedTransactions.csv"))
    end

    # The five-decimal amounts in these files are exactly where a float
    # round-trip loses a cent on a mortgage-sized figure.
    it "reads amounts through BigDecimal" do
      import(row(id: "A1", amount: "-1393.25000"))

      expect(BankTransaction.first.amount_cents).to(eq(-139_325))
    end

    it "reads a parenthesized negative, which is how many exports write one" do
      import(row(id: "A1", amount: "(1,393.25)"))

      expect(BankTransaction.first.amount_cents).to(eq(-139_325))
    end

    it "reads an ISO date as well as a US one" do
      import(row(id: "A1", date: "2026-08-20"))

      expect(User.timezone { BankTransaction.first.occurred_at.to_date.to_s }).to(
        eq("2026-08-20"),
      )
    end
  end

  describe "a mapping that will not work" do
    it "refuses when a required field has no column" do
      expect {
        import(row(id: "A1"), map: mapping.except(:amount))
      }.to(raise_error(described_class::MissingMapping, /Amount/))
    end

    # Choosing a column, then uploading a different bank's file, is the way
    # this goes wrong in practice.
    it "refuses when the mapping names a column the file does not have" do
      expect {
        import(row(id: "A1"), map: mapping.merge(amount: "Total"))
      }.to(raise_error(described_class::MissingMapping, /no column called Total/))
    end
  end

  # The reason this service exists. A bank's export UI gives you a date range,
  # so every upload after the first overlaps the one before it.
  describe "re-uploading an overlapping export" do
    it "updates the rows it already has instead of doubling them" do
      import(row(id: "A1"), row(id: "A2", date: "8/19/2026"))
      result = import(row(id: "A2", date: "8/19/2026"), row(id: "A3", date: "8/18/2026"))

      expect(result.created).to(eq(1))
      expect(result.updated).to(eq(1))
      expect(BankTransaction.count).to(eq(3))
    end

    it "leaves a category that was corrected by hand alone" do
      import(row(id: "A1"), categories: { "Insurance" => "shopping" })
      BankTransaction.first.update!(category: "hobby")

      import(row(id: "A1"), categories: { "Insurance" => "shopping" })

      expect(BankTransaction.first.category).to(eq("hobby"))
    end
  end

  describe "categorizing" do
    it "uses the mapping the person confirmed" do
      import(row(id: "A1", category: "Insurance"), categories: { "Insurance" => "insurance" })

      expect(BankTransaction.first.category).to(eq("insurance"))
    end

    # A blank box is not "leave it uncategorized" — it is "you decide", which
    # is the right answer for a label naming the DIRECTION of the money. MACU
    # files every JPMorgan mortgage debit under "Online Services".
    it "falls through to the merchant rules on a label left blank" do
      wire = "WITHDRAWAL ACH J TYPE: CHASE ACH CO: JPMORGAN CHASE    NAME: ROCCO"
      import(row(id: "A1", category: "Online Services", extended: wire), categories: {})

      expect(BankTransaction.first.category).to(eq("mortgage"))
    end

    # The "INSUR" merchant pattern matches the employer name "WILDCAT
    # INSURANC" and filed seven payroll DEPOSITS as insurance spending, which
    # flipped that category's total positive. An explicit mapping outranks it.
    it "lets the mapping beat a merchant rule that reads the name wrong" do
      wire = "DEPOSIT ACH WILD TYPE: PAYROLL CO: WILDCAT INSURANC ENTRY: ROCCO"
      paycheck = row(id: "A1", amount: "1000.00000", type: "Credit", extended: wire)
      import(
        paycheck.merge("Transaction Category" => "Paychecks/Salary"),
        categories: { "Paychecks/Salary" => "pay check" },
      )

      expect(BankTransaction.first.category).to(eq("pay check"))
    end

    it "leaves a row uncategorized when neither the mapping nor a rule claims it" do
      import(row(id: "A1", description: "SOMETHING NOBODY HAS A RULE FOR"), categories: {})

      expect(BankTransaction.first.category).to(be_nil)
    end

    # `Extra Expense` is in the data exactly once because something wrote a
    # category nothing knows about. A target outside the vocabulary is treated
    # as no answer, the same as a blank box.
    it "treats a mapped value outside our vocabulary as no answer" do
      import(
        row(id: "A1", description: "COSTCO WHSE #1441"),
        categories: { "Insurance" => "Extra Expense" },
      )

      expect(BankTransaction.first.category).to(eq("groceries"))
    end
  end

  describe "an account column" do
    let!(:savings) { BankAccount.create!(name: "MACU Savings (1122)", last4: "1122") }

    def with_account(*rows)
      columns = headers + ["Account"]
      described_class.call(
        csv_for(*rows, columns: columns),
        account: account, mapping: mapping.merge(account: "Account"),
        categories: {}, source: "macu"
      )
    end

    it "matches on the last four" do
      with_account(row(id: "A1").merge("Account" => "Savings ...1122"))

      expect(BankTransaction.first.bank_account).to(eq(savings))
    end

    it "matches on the account name" do
      with_account(row(id: "A1").merge("Account" => "MACU Savings (1122)"))

      expect(BankTransaction.first.bank_account).to(eq(savings))
    end

    # A fallback that refuses to catch things is not one.
    it "falls back to the chosen account when nothing matches" do
      with_account(row(id: "A1").merge("Account" => "Somewhere Else"))

      expect(BankTransaction.first.bank_account).to(eq(account))
    end

    it "reports where the rows went" do
      result = with_account(
        row(id: "A1").merge("Account" => "...1122"),
        row(id: "A2", date: "8/19/2026").merge("Account" => "Unknown Place"),
      )

      expect(result.accounts).to(eq("MACU Savings (1122)" => 1, "MACU Checking (7937)" => 1))
    end

    # A file spread across accounts says nothing about what any one of them
    # ended at, so the last row's running balance belongs to nobody.
    it "does not write a balance" do
      with_account(row(id: "A1", balance: "4391.24000").merge("Account" => "...1122"))

      expect(savings.reload.balance_cents).to(be_nil)
      expect(account.reload.balance_cents).to(be_nil)
    end
  end

  describe "naming the merchant" do
    it "pulls the company out of an ACH wire string" do
      wire = "ACH Withdrawal COMPANY: PRIMERICA LIFE ENTRY: INS. PREM ROCCO NICHOLLS"
      import(row(id: "A1", description: wire, extended: wire))

      expect(BankTransaction.first.payee).to(eq("PRIMERICA LIFE"))
    end

    it "keeps the name the institution already cleaned on a card row" do
      wire = "Withdrawal Debit AIRBNB * HM29F9PN33 AIRBNB.COM CA    Date 10/04/24 27"
      import(row(id: "A1", description: "Airbnb", extended: wire))

      expect(BankTransaction.first.payee).to(eq("Airbnb"))
    end

    it "prefers a real payee column when the file has one" do
      columns = headers + ["Payee"]
      described_class.call(
        csv_for(
          row(id: "A1", extended: "WITHDRAWAL POS # NOISE").merge("Payee" => "Costco"),
          columns: columns,
        ),
        account: account, mapping: mapping.merge(payee: "Payee"),
        categories: {}, source: "macu"
      )

      expect(BankTransaction.first.payee).to(eq("Costco"))
    end
  end

  describe "the account balance" do
    it "takes it from the newest row, whatever order the file is in" do
      import(
        row(id: "A1", date: "8/18/2026", balance: "100.00000"),
        row(id: "A2", date: "8/20/2026", balance: "4391.24000"),
        row(id: "A3", date: "8/19/2026", balance: "200.00000"),
      )

      expect(account.reload.balance_cents).to(eq(439_124))
      expect(User.timezone { account.balance_date.to_date.to_s }).to(eq("2026-08-20"))
    end

    it "refuses to move the balance to an older figure" do
      import(row(id: "A1", date: "8/20/2026", balance: "4391.24000"))
      import(row(id: "A2", date: "1/05/2025", balance: "58172.71000"))

      expect(account.reload.balance_cents).to(eq(439_124))
    end

    # An import must never silently move the dashboard figure. `kind` stays
    # untouched, so a new account is `unknown` and DashboardCache leaves it out.
    it "does not classify the account" do
      import(row(id: "A1"))

      expect(account.reload.kind).to(eq("unknown"))
      expect(SimpleFin::DashboardCache.included?(account.reload)).to(be(false))
    end
  end

  describe "rows it cannot read" do
    it "names them rather than importing something undedupable" do
      result = import(row(id: ""), row(id: "A2"))

      expect(result.created).to(eq(1))
      expect(result.skipped).to(eq(1))
      expect(result.errors.first).to(match(/no Transaction ID/))
    end

    it "skips a row with no usable date or amount" do
      result = import(row(id: "A1", amount: ""), row(id: "A2"))

      expect(result.created).to(eq(1))
      expect(result.skipped).to(eq(1))
    end
  end

  # A CSV row is confirmed by the institution and permanently invisible to the
  # Bridge. Four things branch on simplefin_id being nil to mean "not reported
  # yet", and each was a real bug when it assumed a row implied SimpleFIN.
  describe "keeping clear of the SimpleFIN feed" do
    it "leaves simplefin_id nil" do
      import(row(id: "A1"))

      expect(BankTransaction.first.simplefin_id).to(be_nil)
      expect(BankTransaction.bank_confirmed).to(be_empty)
      expect(BankTransaction.imported.count).to(eq(1))
    end
  end
end
