require "rails_helper"

RSpec.describe AmzUpdatesChannel, type: :channel do
  before do
    AmazonOrder.clear
    allow(MeCache).to receive(:get).and_call_original
    allow(MeCache).to receive(:get).with(:amazon_deliveries).and_return([])
    allow(AmazonOrder).to receive(:save)
    allow(AmazonOrder).to receive(:broadcast)
    stub_connection
    subscribe
  end

  describe "merge action (`2+4`)" do
    it "folds the source item into the target, keeping the target's name" do
      target = AmazonOrder.create(order_id: "CUSTOM", item_id: "CUSTOM-1", name: "New shoes", carrier: :manual, email_ids: [1])
      AmazonOrder.create(
        order_id: "UPS", item_id: "1Z16D56V0310080972", name: "NINGBO DEYI SAM",
        carrier: :ups, tracking_number: "1Z16D56V0310080972", source: "NINGBO DEYI SAM",
        delivery_date: "2026-08-03", delivered: false, email_ids: [2],
      )

      perform :change, {
        "merge"         => true,
        "order_id"      => "CUSTOM",
        "item_id"       => "CUSTOM-1",
        "from_order_id" => "UPS",
        "from_item_id"  => "1Z16D56V0310080972",
      }

      expect(target.name).to eq("New shoes")            # target's display kept
      expect(target.carrier).to eq(:ups)                # adopted
      expect(target.tracking_number).to eq("1Z16D56V0310080972")
      expect(target.source).to eq("NINGBO DEYI SAM")
      expect(target.delivery_date).to eq("2026-08-03")
      expect(target.email_ids).to contain_exactly(1, 2) # unioned
      expect(AmazonOrder.all).to contain_exactly(target) # source destroyed
    end

    it "is a no-op when target and source are the same item" do
      only = AmazonOrder.create(order_id: "UPS", item_id: "1Zsame", name: "X", carrier: :ups)

      perform :change, {
        "merge"         => true,
        "order_id"      => "UPS",
        "item_id"       => "1Zsame",
        "from_order_id" => "UPS",
        "from_item_id"  => "1Zsame",
      }

      expect(AmazonOrder.all).to contain_exactly(only)
    end
  end

  describe "add action" do
    it "creates a manual-carrier item" do
      perform :change, { "add" => "Birthday gift" }

      created = AmazonOrder.all.last
      expect(created.name).to eq("Birthday gift")
      expect(created.carrier).to eq(:manual)
    end

    it "parses an inline metadata block: name, date, and custom url" do
      url = "https://www.wayfair.com/session/secure/account/order_search.php?csnid=978882AB&_emr=fac652f5&wfcs=cs7"
      perform :change, { "add" => %(Computer Desk on Aug 7 { url: "#{url}" }) }

      created = AmazonOrder.all.last
      expect(created.name).to eq("Computer Desk")
      expect(created.custom_url).to eq(url)
      expect(created.delivery_date).to eq(Date.new(Date.current.year + (Date.current.month > 8 ? 1 : 0), 8, 7).iso8601)
      # The URL's digits must not leak into the name.
      expect(created.name).not_to match(/\d/)
    end

    it "seeds a tracking number from metadata so a later carrier update auto-connects" do
      perform :change, { "add" => %(Desk { tracking_number: "9200190267338000065163052", source: "Wayfair" }) }
      seeded = AmazonOrder.all.last
      expect(seeded.tracking_number).to eq("9200190267338000065163052")
      expect(seeded.source).to eq("Wayfair")

      hit = Shipments::Connector.connect_or_create(carrier: :usps, tracking_number: "9200190267338000065163052")
      expect(hit).to be(seeded) # strong-matched the pre-seeded item
    end
  end

  describe "merge keeps the target's custom url" do
    it "does not overwrite the target's link when merging a carrier shipment in" do
      target = AmazonOrder.create(order_id: "CUSTOM", item_id: "CUSTOM-9", name: "Computer Desk", carrier: :manual, custom_url: "https://wayfair.com/x")
      AmazonOrder.create(order_id: "UPS", item_id: "1Zdesk", name: "NINGBO", carrier: :ups, tracking_number: "1Zdesk")

      perform :change, {
        "merge" => true, "order_id" => "CUSTOM", "item_id" => "CUSTOM-9",
        "from_order_id" => "UPS", "from_item_id" => "1Zdesk",
      }

      expect(target.custom_url).to eq("https://wayfair.com/x") # kept
      expect(target.tracking_number).to eq("1Zdesk")           # adopted
      expect(target.name).to eq("Computer Desk")               # kept
    end
  end
end
