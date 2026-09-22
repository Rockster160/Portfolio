require "rails_helper"

# The two-way binding between an Amazon charge's note and the name on the
# delivery board. Before this, the name was copied once when the charge landed
# and never again: renaming the row left the memo and the unanswered
# categorization prompt both reading whatever the shipping email had guessed.
RSpec.describe SimpleFin::AmazonNote do
  let(:user) { User.me }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "A2", name: "Prime Visa (7283)", last4: "7283", kind: :credit,
    )
  }
  let(:at) { Time.utc(2026, 9, 21, 21, 14) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    stock!([])
  end

  def row(overrides={})
    {
      "order_id"      => "114-0471911-2289867",
      "item_id"       => "B0C1XLC962",
      "listed_name"   => "item: Health Care",
      "full_name"     => nil,
      "name"          => "item: Health Care",
      "delivery_date" => "2026-09-23",
      "amount"        => 7.1,
      "carrier"       => "amazon",
      "email_ids"     => [],
      "errors"        => [],
    }.merge(overrides)
  end

  def stock!(rows)
    MeCache.set(:amazon_deliveries, rows)
    AmazonOrder.clear
  end

  def charge(overrides={})
    BankTransaction.create!(
      {
        simplefin_id:  "TRN-1",
        bank_account:  card,
        transacted_at: at,
        posted_at:     at,
        amount_cents:  -710,
        payee:         "AMAZON MKTPLACE PMTS",
        category:      "shopping",
        metadata:      { "amazon" => { "order_id" => "114-0471911-2289867", "item_id" => "B0C1XLC962" } },
      }.merge(overrides),
    )
  end

  describe ".for_order" do
    it "takes a name that has diverged from the listed one as the one somebody typed" do
      order = AmazonOrder.new(row("name" => "Pill Box", "full_name" => "Weekly Pill Organizer, 7 Day, BPA Free"))

      expect(described_class.for_order(order)).to eq("Pill Box")
    end

    it "falls back to the product title, shortened, over the department it was filed under" do
      order = AmazonOrder.new(row("full_name" => "Weekly Pill Organizer, 7 Day, BPA Free, 2 Pack"))

      expect(described_class.for_order(order)).to eq("Weekly Pill Organizer")
    end

    it "uses the listed name when there is no title at all" do
      expect(described_class.for_order(AmazonOrder.new(row))).to eq("item: Health Care")
    end

    it "answers nothing for no order" do
      expect(described_class.for_order(nil)).to be_nil
    end
  end

  describe ".rename!" do
    it "renames the row the charge paid for" do
      stock!([row])
      transaction = charge

      expect(described_class.rename!(transaction, "Pill Box")).to be(true)

      AmazonOrder.clear
      expect(AmazonOrder.find("114-0471911-2289867").name).to eq("Pill Box")
    end

    it "carries the new name onto the charge, through the delivery trigger" do
      stock!([row])
      transaction = charge

      described_class.rename!(transaction, "Pill Box")

      expect(transaction.reload.memo).to eq("Pill Box")
    end

    it "leaves the board alone for a charge that matches nothing on it" do
      stock!([])

      expect(described_class.rename!(charge, "Pill Box")).to be(false)
    end

    it "does not clear a name" do
      stock!([row])

      expect(described_class.rename!(charge, "  ")).to be(false)
    end

    it "says nothing moved when the board already says that" do
      stock!([row("name" => "Pill Box")])

      expect(described_class.rename!(charge, "Pill Box")).to be(false)
    end
  end

  describe ".push!" do
    it "touches only the charge for its own half of a split shipment" do
      stock!([
        row("item_id" => "ASIN-A", "name" => "Pill Box"),
        row("item_id" => "ASIN-B", "name" => "Dog Pads"),
      ])
      mine = charge(
        simplefin_id: "TRN-A",
        metadata:     { "amazon" => { "order_id" => "114-0471911-2289867", "item_id" => "ASIN-A" } },
      )
      theirs = charge(
        simplefin_id: "TRN-B", memo: "Dog Pads",
        metadata: { "amazon" => { "order_id" => "114-0471911-2289867", "item_id" => "ASIN-B" } }
      )

      expect(described_class.push!(AmazonOrder.find("114-0471911-2289867", "ASIN-A"))).to eq(1)
      expect(mine.reload.memo).to eq("Pill Box")
      expect(theirs.reload.memo).to eq("Dog Pads")
    end
  end

  describe "the categorization prompt" do
    def prompt_for(transaction, default: "item: Health Care")
      Prompt.create!(
        user:     user,
        question: "$7.1 at AMAZON MKTPLACE PMTS",
        params:   { "source" => "transaction_categorize", "action_event_id" => transaction.action_event_id },
        options:  [
          { "type" => "select", "question" => "Category", "choices" => ["shopping"], "default" => "shopping" },
          { "type" => "textarea", "question" => "Notes", "default" => default },
        ],
      )
    end

    def event_for(transaction)
      event = ActionEvent.create!(user: user, name: "Transaction", timestamp: at, data: { "amount" => 7.1 })
      transaction.update!(action_event: event)
      transaction
    end

    it "fills the Notes box from the board as the prompt is opened" do
      stock!([row("name" => "Pill Box")])
      prompt = prompt_for(event_for(charge))

      described_class.dispatch(user, :prompt, prompt.with_jil_attrs(state: :load))

      notes = prompt.reload.options.find { |o| o["question"] == "Notes" }
      expect(notes["default"]).to eq("Pill Box")
    end

    it "leaves the box alone when the charge is on nothing the board holds" do
      stock!([])
      prompt = prompt_for(event_for(charge), default: "")

      described_class.dispatch(user, :prompt, prompt.with_jil_attrs(state: :load))

      expect(prompt.reload.options.last["default"]).to eq("")
    end

    it "renames the row from the note that was typed into it" do
      stock!([row])
      transaction = event_for(charge(memo: "item: Health Care"))
      prompt = prompt_for(transaction)
      prompt.update!(response: { "Category" => "health", "Notes" => "Pill Box" })

      described_class.dispatch(user, :prompt, prompt.with_jil_attrs(status: :complete))

      AmazonOrder.clear
      expect(AmazonOrder.find("114-0471911-2289867").name).to eq("Pill Box")
      expect(transaction.reload.memo).to eq("Pill Box")
    end

    it "ignores a prompt that is not the transaction one" do
      stock!([row])
      prompt = prompt_for(event_for(charge))
      prompt.update!(params: { "source" => "plunge" }, response: { "Notes" => "Pill Box" })

      described_class.dispatch(user, :prompt, prompt.with_jil_attrs(status: :complete))

      AmazonOrder.clear
      expect(AmazonOrder.find("114-0471911-2289867").name).to eq("item: Health Care")
    end
  end

  it "does not point somebody else's companion at his packages" do
    stock!([row])
    other = User.create!(username: "notme-#{SecureRandom.hex(4)}", password: "abcd1234!", password_confirmation: "abcd1234!")
    prompt = Prompt.create!(
      user: other, question: "x",
      params: { "source" => "transaction_categorize", "action_event_id" => 1 },
      options: [{ "type" => "textarea", "question" => "Notes", "default" => "" }]
    )

    expect {
      described_class.dispatch(other, :prompt, prompt.with_jil_attrs(state: :load))
    }.not_to(change { prompt.reload.options })
  end
end
