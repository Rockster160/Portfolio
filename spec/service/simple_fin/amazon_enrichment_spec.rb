require "rails_helper"

# The live counterpart to the order-history backfill: an Amazon charge picks up
# its order number, item id, item name and category from the delivery board.
RSpec.describe SimpleFin::AmazonEnrichment do
  let(:user) { User.me }
  let!(:card) {
    BankAccount.create!(
      simplefin_id: "A2", name: "AMZ Prime (7283)", last4: "7283", kind: :credit,
    )
  }
  let(:at) { Time.utc(2026, 8, 10, 18) }

  def delivery(overrides={})
    AmazonOrder.new(
      {
        "order_id"      => "112-6608200-0828238",
        "item_id"       => "B0C1XLC962",
        "name"          => "Dogcator Dog Pee Pads Extra Large, 30 Count",
        "amount"        => "24.99",
        "delivery_date" => "2026-08-11",
      }.merge(overrides),
    )
  end

  def board(*orders)
    allow(AmazonOrder).to receive(:all).and_return(orders)
  end

  def charge(cents: -2499, payee: "AMAZON MKTPLACE PMTS", memo: nil, category: "shopping")
    BankTransaction.create!(
      simplefin_id: "TRN-1", bank_account: card, transacted_at: at, posted_at: at,
      amount_cents: cents, payee: payee, memo: memo, category: category
    )
  end

  it "writes the order number and item id onto the charge" do
    board(delivery)
    row = charge

    described_class.apply(row)

    expect(row.reload.metadata.dig("amazon", "order_id")).to eq("112-6608200-0828238")
    expect(row.metadata.dig("amazon", "item_ids")).to eq(["B0C1XLC962"])
  end

  it "names the item in the memo, tidied the same way the backfill did" do
    board(delivery)
    row = charge

    described_class.apply(row)

    expect(row.reload.memo).to eq("Dogcator Dog Pee Pads Extra Large")
  end

  it "moves it off the merchant's blanket shopping" do
    board(delivery)
    row = charge

    described_class.apply(row)

    expect(row.reload.category).to eq("pets")
  end

  # A title is search spam and mentions everything the thing could be near.
  # This exact soup bowl was filed under groceries because its title says
  # "Stoneware Cereal Set of 4".
  it "categorizes on the tidied name, not the keyword spam in the title" do
    board(delivery(
            "name"   => "27.0 Oz Large Soup Bowls, Stoneware Cereal Set of 4, " \
                        "modern dark petrol-Blue Pasta Bowl for Kitchen",
            "amount" => "24.99",
          ))
    row = charge

    described_class.apply(row)

    expect(row.reload.memo).to eq("27.0 Oz Large Soup Bowls")
    expect(row.category).to eq("shopping")
  end

  it "leaves a memo that was typed by hand" do
    board(delivery)
    row = charge(memo: "Puppy Bed Treats")

    described_class.apply(row)

    expect(row.reload.memo).to eq("Puppy Bed Treats")
    # The order number is a fact about the purchase, not an opinion, so it
    # still lands.
    expect(row.metadata.dig("amazon", "order_id")).to be_present
  end

  it "ignores a charge that is not Amazon" do
    board(delivery)
    row = charge(payee: "COSTCO WHSE #1043")

    expect(described_class.apply(row)).to be_nil
    expect(row.reload.metadata).to eq({})
  end

  it "ignores a delivery of a different size" do
    board(delivery("amount" => "99.00"))
    row = charge

    expect(described_class.apply(row)).to be_nil
  end

  it "ignores a delivery outside the window" do
    board(delivery("delivery_date" => "2026-09-20"))
    row = charge

    expect(described_class.apply(row)).to be_nil
  end

  # The board also holds hand-added rows and other carriers.
  it "ignores a board row that is not a real Amazon order" do
    board(delivery("order_id" => "CUSTOM"))
    row = charge

    expect(described_class.apply(row)).to be_nil
  end

  # One delivery explains one charge; without this two same-sized charges would
  # both claim it and one would be wrong.
  it "does not let two charges claim the same delivery" do
    board(delivery)
    first = charge
    described_class.apply(first)

    second = BankTransaction.create!(
      simplefin_id: "TRN-2", bank_account: card, transacted_at: at, posted_at: at,
      amount_cents: -2499, payee: "AMAZON MKTPLACE PMTS", category: "shopping"
    )

    expect(described_class.apply(second)).to be_nil
  end

  it "does nothing the second time" do
    board(delivery)
    row = charge
    described_class.apply(row)

    expect { described_class.apply(row) }.not_to(change { row.reload.updated_at })
  end

  # The board is a cache, and a charge is not worth failing a sync over.
  it "survives an unreadable delivery board" do
    allow(AmazonOrder).to receive(:all).and_raise(StandardError, "cache gone")
    row = charge

    expect { described_class.apply(row) }.not_to raise_error
  end

  it "runs when the bank reports a new Amazon charge" do
    board(delivery)

    SimpleFin::Sync.call(
      "accounts" => [{
        "id"           => "A2",
        "name"         => "AMZ Prime (7283)",
        "balance"      => "-10.00",
        "transactions" => [{
          "id"            => "TRN-NEW",
          "posted"        => at.to_i,
          "transacted_at" => at.to_i,
          "amount"        => "-24.99",
          "description"   => "AMAZON MKTPLACE PMTS",
          "payee"         => "Amazon",
        }],
      }],
    )

    expect(BankTransaction.find_by(simplefin_id: "TRN-NEW").metadata.dig("amazon", "order_id"))
      .to eq("112-6608200-0828238")
  end
end
