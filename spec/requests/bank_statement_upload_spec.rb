require "rails_helper"

# The upload form on /system/banking is the whole point of the importer: a bank
# export lands on a laptop, and every path that isn't "pick the file and press
# the button" ends with somebody pasting data into a console.
RSpec.describe "Bank statement upload", type: :request do
  let(:user) { User.me }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post(login_path, params: { user: { username: user.username, password: "password123" } })
  end

  # Tempfile rather than a path under tmp/: Rack::Test::UploadedFile needs a
  # real file on disk, and a spec that leaves one behind per example fills the
  # directory with unreadable hex names nobody ever deletes.
  def csv_file(body, name: "ExportedTransactions.csv")
    file = Tempfile.new(["export", ".csv"])
    file.write(body)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: name)
  end

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

  def export(*rows)
    CSV.generate { |out|
      out << headers
      rows.each { |row| out << headers.map { |header| row[header] } }
    }
  end

  def row(
    id:,
    amount: "-27.71000",
    date: "8/20/2026",
    description: "Primerica",
    category: "Insurance",
    balance: "4391.24000")
    {
      "Transaction ID"       => id,
      "Posting Date"         => date,
      "Effective Date"       => "",
      "Transaction Type"     => "Debit",
      "Amount"               => amount,
      "Check Number"         => "",
      "Reference Number"     => "42737",
      "Description"          => description,
      "Transaction Category" => category,
      "Type"                 => "Retail ACH",
      "Balance"              => balance,
      "Memo"                 => "",
      "Extended Description" => description,
    }
  end

  # What the mapping screen would have posted back after the person accepted
  # the proposal — the real form always sends one.
  def mapping_for(columns=nil)
    BankStatementImporter.guess(columns || headers)
  end

  def upload(body, **params)
    defaults = { file: csv_file(body), mapping: mapping_for, source: "macu" }
    post(system_bank_import_path, params: defaults.merge(params))
  end

  def inspect_upload(body, filename: "ExportedTransactions.csv")
    post(system_bank_import_inspect_path, params: { file: csv_file(body, name: filename) })
    response.parsed_body
  end

  # The mapping panel is drawn by JavaScript, so the Import button sits outside
  # the hidden region and still works if the script never runs. The form lives
  # in a modal, and the new-account name is required in the markup so the
  # browser refuses a submit with neither account field filled.
  it "renders the import form on the banking page", :aggregate_failures do
    get(system_banking_path)

    expect(response).to(have_http_status(:ok))
    expect(response.body).to(include(system_bank_import_path, system_bank_import_inspect_path))

    hidden = response.body[/<div class="bank-import-panels hidden".*?<\/div>\s*<\/section>\s*<\/div>/m]
    expect(response.body).to(include("bank-import-always"))
    expect(hidden.to_s).not_to(include("Import"))

    expect(response.body).to(include('data-modal="#bank-import"'))
    expect(response.body).to(match(/<div class="modal modal-wrapper hidden[^"]*" id="bank-import"/))

    field = response.body[/<input[^>]*id="bank-import-new"[^>]*>/]
    expect(field).to(include("required"))
  end

  # The mapping screen is drawn from this, on the client, the moment a file is
  # chosen. It must never write anything — the person has not agreed to
  # anything yet.
  describe "inspecting a file before importing it" do
    it "answers with the columns, a proposed mapping, the row count and categories, writing nothing", :aggregate_failures do
      body = nil
      expect {
        body = inspect_upload(
          export(row(id: "A1", category: "Insurance"), row(id: "A2", date: "8/19/2026", category: "Groceries")),
        )
      }.not_to(change(BankTransaction, :count))

      expect(body["headers"]).to(include("Transaction ID", "Extended Description"))
      expect(body["mapping"]).to(include("identifier" => "Transaction ID", "amount" => "Amount"))
      expect(body["rows"]).to(eq(2))
      expect(body["source"]).to(eq("macu"))
      expect(body["categories"]).to(eq("Groceries" => "groceries", "Insurance" => "insurance"))
      expect(body["vocabulary"]).to(include("groceries", "mortgage"))
    end

    it "says so on a file that will not parse" do
      inspect_upload("\"unclosed,quote\n1,2\n")

      expect(response).to(have_http_status(:bad_request))
      expect(response.parsed_body["error"]).to(be_present)
    end
  end

  # Submitting with no mapping has to work, or a broken script takes the whole
  # feature with it.
  it "falls back to the guessed mapping when none is posted" do
    post(system_bank_import_path, params: {
      file:             csv_file(export(row(id: "A1"), row(id: "A2", date: "8/19/2026"))),
      new_account_name: "MACU Checking (7937)",
    })

    expect(BankTransaction.count).to(eq(2))
    expect(BankTransaction.first.payee).to(be_present)
  end

  # An upload must never move the headline figure on its own — the person
  # classifies the account when they are ready for it to count.
  it "creates a named new account, imports into it, and leaves it out of the dashboard", :aggregate_failures do
    upload(
      export(row(id: "A1"), row(id: "A2", date: "8/19/2026")),
      new_account_name: "MACU Checking (7937)",
    )

    expect(response).to(redirect_to(system_banking_path))
    account = BankAccount.find_by!(name: "MACU Checking (7937)")
    expect(account.bank_transactions.count).to(eq(2))
    expect(account.last4).to(eq("7937"))
    expect(account.kind).to(eq("unknown"))
    expect(SimpleFin::DashboardCache.included?(account)).to(be(false))
  end

  # The category boxes are named `categories[<the bank's own label>]`, and bank
  # labels are full of characters that mean something in a form field name.
  # "Restaurants & Dining" and "Paychecks/Salary" are both real MACU labels.
  it "round-trips a category label containing & and /" do
    upload(
      export(
        row(id: "A1", category: "Restaurants & Dining"),
        row(id: "A2", date: "8/19/2026", category: "Paychecks/Salary"),
      ),
      new_account_name: "MACU",
      categories:       { "Restaurants & Dining" => "eat out", "Paychecks/Salary" => "pay check" },
    )

    expect(BankTransaction.pluck(:category)).to(contain_exactly("eat out", "pay check"))
  end

  describe "uploading into an account that already exists" do
    let!(:account) { BankAccount.create!(name: "MACU Checking (7937)", last4: "7937") }

    it "adds to it rather than making a second one" do
      upload(export(row(id: "A1")), bank_account_id: account.id)

      expect(BankAccount.count).to(eq(1))
      expect(account.bank_transactions.count).to(eq(1))
    end

    # The reason the service exists: a bank's export UI gives you a date range,
    # so every upload after the first overlaps the one before it.
    it "reports the overlap instead of doubling it" do
      upload(
        export(row(id: "A1"), row(id: "A2", date: "8/19/2026")),
        bank_account_id: account.id,
      )
      upload(
        export(row(id: "A2", date: "8/19/2026"), row(id: "A3", date: "8/18/2026")),
        bank_account_id: account.id,
      )

      expect(account.bank_transactions.count).to(eq(3))
    end
  end

  describe "when it cannot be read" do
    # Choosing columns, then submitting a different bank's file, is how a
    # mapping comes to name columns that are not there.
    it "redirects with an alert and writes nothing on a mapping, file or account it can't use" do
      [
        -> { upload("When,How much\n8/20/2026,-27.71\n", new_account_name: "Somewhere") },
        -> { upload(export(row(id: "A1")), new_account_name: "Somewhere", mapping: mapping_for.except(:amount)) },
        -> { post(system_bank_import_path, params: { new_account_name: "MACU" }) },
        -> { upload(export(row(id: "A1"))) },
      ].each do |attempt|
        attempt.call

        expect(response).to(redirect_to(system_banking_path))
        expect(flash[:alert]).to(be_present)
      end
      expect(BankTransaction.count).to(be_zero)
    end

    # Half a statement is worse than none — there is no way to tell which half,
    # and the next move is to upload it again.
    it "writes nothing at all when a row blows up mid-file" do
      account = BankAccount.create!(name: "MACU Checking (7937)")
      # The second row fails, after the first has already been written.
      call = 0
      allow_any_instance_of(BankTransaction).to(receive(:save!)) {
        call += 1
        raise(ActiveRecord::RecordInvalid) if call > 1
      }

      upload(export(row(id: "A1"), row(id: "A2")), bank_account_id: account.id)

      expect(BankTransaction.count).to(be_zero)
    end
  end
end
