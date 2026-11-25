require "rails_helper"

RSpec.describe "Invoices", type: :request do
  let(:user) { User.me }
  let!(:issued) { AppDevice.issue!(user, name: "Phone") }
  let(:headers) { { "Authorization" => "Bearer #{issued.last}" } }

  let(:year) { Date.current.year }

  def invoice_for(recipient, **attributes)
    user.invoices.create!(issued_on: Date.current, recipient: recipient, **attributes)
  end

  it "starts a new invoice from the last one, as that client's next number", :aggregate_failures do
    invoice_for(
      "Agent Boost Marketing\nLehi",
      due_on: Date.current + 7,
      sender: "Pat Doe\n1 Main St",
      notes:  "Direct deposit",
    )

    post invoices_path, headers: headers
    invoice = user.invoices.order(:id).last

    expect(response).to redirect_to(edit_invoice_path(invoice))
    expect(invoice.number).to eq("#{year}-ABM-002")
    expect(invoice.sender).to eq("Pat Doe\n1 Main St")
    expect(invoice.recipient).to eq("Agent Boost Marketing\nLehi")
    expect(invoice.due_on - invoice.issued_on).to eq(7)
    expect(invoice.total).to eq(0)
  end

  it "counts each client on its own and keeps clients with the same initials apart" do
    numbers = ["Acme Co", "Apex Co", "Acme Co", "Globex"].map { |name| invoice_for(name).number }

    expect(numbers).to eq(["#{year}-AC-001", "#{year}-AC2-001", "#{year}-AC-002", "#{year}-GLO-001"])
  end

  it "follows a change of client, but keeps a number typed over it", :aggregate_failures do
    invoice_for("Acme Co")
    moved = invoice_for("Acme Co")
    typed = invoice_for("Acme Co", number: "CUSTOM-9")

    moved.update!(recipient: "Globex\nSpringfield")
    typed.update!(recipient: "Globex")

    expect(moved.number).to eq("#{year}-GLO-001")
    expect(typed.number).to eq("CUSTOM-9")
  end

  it "saves edits and answers with the redrawn sheet", :aggregate_failures do
    invoice = user.invoices.create!(number: "A-1", issued_on: Date.current)

    patch invoice_path(invoice), params: {
      invoice: {
        recipient: "Acme Co\nAttn: Billing",
        items:     [
          { description: "Build", quantity: "2", rate: "1,250" },
          { description: "", quantity: "1", rate: "" },
        ],
      },
    }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(invoice.reload.total).to eq(2500)
    sheet = response.parsed_body["sheet"]
    expect(sheet).to include("Acme Co<br>Attn: Billing")
    expect(sheet).to include("$2,500.00")
    expect(sheet.scan("<tr>").size).to eq(2)
  end

  it "fills a cleared number back in" do
    invoice = invoice_for("Acme Co", number: "CUSTOM-9")

    patch invoice_path(invoice), params: { invoice: { number: "" } }, headers: headers, as: :json

    expect(response.parsed_body["number"]).to eq("#{year}-AC-001")
  end

  it "never shows another person's invoice" do
    other = User.create!(username: "someone_else", password: "password", password_confirmation: "password")
    invoice = other.invoices.create!(number: "B-1", issued_on: Date.current)

    get invoice_path(invoice), headers: headers

    expect(response).to have_http_status(:redirect)
    expect(response.body).not_to include("B-1")
  end
end
