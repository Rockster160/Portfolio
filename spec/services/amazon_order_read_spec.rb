require "rails_helper"

RSpec.describe AmazonOrderRead do
  let(:user) { User.me }
  let(:order_id) { "111-4653427-0102644" }
  let(:litter) { item("B000PKSW2I", "Precious Cat Classic Premium Clumping Cat Litter, 40 lb Bag") }
  let(:gloves) { item("B0861WJ3CY", "INBIKE Motorcycle Gloves Breathable Mesh Touchscreen Hard Knuckles") }

  def shipment(status, items, promise: status, promise_box: "", tracking_id: nil)
    { status: status, promise: promise, promise_box: promise_box, tracking_id: tracking_id, items: items }
  end

  def item(asin, title, text: title)
    { asin: asin, title: title, quantity: 1, text: text }
  end

  def read(*orders)
    described_class.apply!({ read_at: Time.current.iso8601, orders: orders }.deep_stringify_keys, user: user)
    AmazonOrder.reload
  end

  def row(asin, order=order_id)
    AmazonOrder.find(order, asin)
  end

  before do
    AmazonOrder.clear
    allow(AmazonOrder).to receive(:broadcast)
    allow(DeliveryEvents).to receive(:fire!)
    allow(AmazonFriendlyName).to receive(:call) { |titles, **| titles.map { |title| "Name for #{title.split.first}" } }
  end

  around do |example|
    travel_to(Time.find_zone("America/Denver").local(2026, 11, 12, 18)) { example.run }
  end

  it "names the item and gives it the day and window it's expected" do
    allow(AmazonFriendlyName).to receive(:call).and_return(["Kitty Litter"])

    read({
      order_id:  order_id,
      shipments: [
        shipment(
          "Arriving tomorrow",
          [litter],
          promise_box: "Arriving tomorrow 10 AM - 2 PM",
          tracking_id: "TBA336410662589",
        ),
      ],
    })

    expect(row("B000PKSW2I")).to have_attributes(
      name:            "Kitty Litter",
      full_name:       litter[:title],
      delivery_date:   "2026-11-13",
      time_range:      "10-2PM",
      tracking_number: "TBA336410662589",
      delivered:       be_falsey,
    )
  end

  it "names a product once, and keeps a name it was given by hand" do
    AmazonItemCatalog.set("B000PKSW2I", name: "Cat Litter", source: :typed)

    read({ order_id: order_id, shipments: [shipment("Arriving tomorrow", [litter])] })

    expect(row("B000PKSW2I").name).to eq("Cat Litter")
    expect(AmazonFriendlyName).not_to have_received(:call)
  end

  it "renames a product whose old name is only a cut-down title" do
    AmazonItemCatalog.set("B0861WJ3CY", name: "INBIKE Breathable Mesh")
    allow(AmazonFriendlyName).to receive(:call).and_return(["Bike Gloves"])

    read({ order_id: order_id, shipments: [shipment("Arriving tomorrow", [gloves])] })

    expect(row("B0861WJ3CY").name).to eq("Bike Gloves")
    expect(AmazonItemCatalog.get("B0861WJ3CY")[:name]).to eq("Bike Gloves")
  end

  it "keeps an old name in the person's own words" do
    AmazonItemCatalog.set("B0861WJ3CY", name: "Riding Gloves")

    read({ order_id: order_id, shipments: [shipment("Arriving tomorrow", [gloves])] })

    expect(row("B0861WJ3CY").name).to eq("Riding Gloves")
    expect(AmazonFriendlyName).not_to have_received(:call)
  end

  it "shows the whole thing when naming fails, rather than a cut, and asks again next time" do
    allow(AmazonFriendlyName).to receive(:call).and_return([nil])

    read({ order_id: order_id, shipments: [shipment("Arriving tomorrow", [gloves])] })

    expect(row("B0861WJ3CY").name).to include("Gloves")
    expect(AmazonItemCatalog.get("B0861WJ3CY")).to be_nil
  end

  it "replaces the stand-in an email made for the order, keeping a name given to it by hand" do
    AmazonOrder.create(
      order_id:    order_id,
      item_id:     order_id,
      listed_name: "Pet Supplies",
      name:        "Cat stuff",
      email_ids:   [52_952],
    )
    AmazonOrder.save

    read({ order_id: order_id, shipments: [shipment("Arriving tomorrow", [litter])] })

    expect(row(order_id)).to be_nil
    expect(row("B000PKSW2I")).to have_attributes(name: "Cat stuff", email_ids: [52_952])
  end

  it "tracks each package of one order on its own" do
    read({
      order_id:  order_id,
      shipments: [
        shipment("Delivered November 11 Your package was left near the front door or porch.", [litter]),
        shipment("Arriving Monday", [gloves]),
      ],
    })

    expect(row("B000PKSW2I")).to have_attributes(delivered: true, delivery_date: "2026-11-11")
    expect(row("B0861WJ3CY")).to have_attributes(delivered: be_falsey, delivery_date: "2026-11-16")
  end

  it "moves an item to the day it's now expected" do
    read({ order_id: order_id, shipments: [shipment("Arriving tomorrow", [gloves])] })

    read({ order_id: order_id, shipments: [shipment("Now arriving November 18", [gloves])] })

    expect(row("B0861WJ3CY").delivery_date).to eq("2026-11-18")
  end

  it "marks a cancelled item cancelled" do
    read({
      order_id:  order_id,
      shipments: [shipment("Cancelled Your order was cancelled.", [gloves], promise: nil)],
    })

    expect(row("B0861WJ3CY").status).to eq(:cancelled)
  end

  it "doesn't bring back an item removed after it arrived" do
    read({
      order_id:  order_id,
      shipments: [shipment("Delivered November 11", [litter]), shipment("Arriving Monday", [gloves])],
    })
    row("B000PKSW2I").remove!
    AmazonOrder.save

    read({
      order_id:  order_id,
      shipments: [shipment("Delivered November 11", [litter]), shipment("Arriving tomorrow", [gloves])],
    })

    expect(row("B000PKSW2I")).to be_nil
    expect(row("B0861WJ3CY").delivery_date).to eq("2026-11-13")
  end

  it "doesn't undo an item marked delivered by hand" do
    read({ order_id: order_id, shipments: [shipment("Arriving Monday", [gloves])] })
    row("B0861WJ3CY").delivered = true
    AmazonOrder.save

    read({ order_id: order_id, shipments: [shipment("Arriving tomorrow", [gloves])] })

    expect(row("B0861WJ3CY")).to have_attributes(delivered: true, delivery_date: "2026-11-16")
  end

  it "leaves an order it couldn't read as it was" do
    read({ order_id: order_id, shipments: [shipment("Arriving Monday", [gloves])] })

    read({ order_id: order_id, error: "Timeout 10000ms exceeded" })

    expect(row("B0861WJ3CY").delivery_date).to eq("2026-11-16")
  end

  it "asks for a person when Amazon wants one, until a read gets through" do
    described_class.apply!({ "error" => "Amazon asked for a captcha", "needs_person" => true }, user: user)
    note = BackgroundProcess.find_by(user: user, key: described_class::SIGN_IN_KEY)
    expect(note).to have_attributes(name: "Amazon sign-in", detail: "Amazon asked for a captcha")

    read({ order_id: order_id, shipments: [shipment("Arriving Monday", [gloves])] })

    expect(note.reload).to be_finished
  end
end
