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
  end
end
