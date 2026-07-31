RSpec.describe Shipments::Connector do
  before do
    AmazonOrder.clear
    allow(MeCache).to receive(:get).and_call_original
    allow(MeCache).to receive(:get).with(:amazon_deliveries).and_return([])
    allow(AmazonOrder).to receive(:save)
    allow(AmazonOrder).to receive(:broadcast)
  end

  def seed(**attrs)
    AmazonOrder.create(attrs)
  end

  describe ".connect_or_create" do
    it "STRONG-matches an existing item by exact tracking number" do
      existing = seed(carrier: :ups, tracking_number: "1Z16D56V0310080972", source: "NINGBO")

      hit = described_class.connect_or_create(
        carrier: :ups, tracking_number: "1Z16D56V0310080972", source: "NINGBO",
      )

      expect(hit).to be(existing)
      expect(AmazonOrder.all.size).to eq(1)
    end

    it "WEAK-matches a single active same-source item and back-fills tracking without changing item_id" do
      existing = seed(carrier: :ups, source: "NINGBO DEYI SAM", item_id: "UPS-abcd", delivered: false)

      hit = described_class.connect_or_create(
        carrier: :ups, source: "NINGBO DEYI SAM", tracking_number: "1Z99AA88BB77CC6655",
      )

      expect(hit).to be(existing)
      expect(hit.item_id).to eq("UPS-abcd")               # identity unchanged
      expect(hit.tracking_number).to eq("1Z99AA88BB77CC6655") # back-filled
      expect(AmazonOrder.all.size).to eq(1)
    end

    it "creates a NEW item when the source is ambiguous (more than one active match)" do
      seed(carrier: :ups, source: "NINGBO", item_id: "UPS-a", delivered: false)
      seed(carrier: :ups, source: "NINGBO", item_id: "UPS-b", delivered: false)

      hit = described_class.connect_or_create(carrier: :ups, source: "NINGBO")

      expect(AmazonOrder.all.size).to eq(3)
      expect([ "UPS-a", "UPS-b" ]).not_to include(hit.item_id)
    end

    it "never WEAK-matches a delivered item" do
      delivered = seed(carrier: :ups, source: "NINGBO", item_id: "UPS-done", delivered: true)

      hit = described_class.connect_or_create(carrier: :ups, source: "NINGBO")

      expect(hit).not_to be(delivered)
      expect(AmazonOrder.all.size).to eq(2)
    end

    it "creates with tracking number as item_id when present, else a synthetic id" do
      with_tracking = described_class.connect_or_create(carrier: :usps, tracking_number: "9200190267338000065163052")
      no_tracking   = described_class.connect_or_create(carrier: :ups, source: "AMPLETHINK")

      expect(with_tracking.item_id).to eq("9200190267338000065163052")
      expect(with_tracking.order_id).to eq("USPS")
      expect(no_tracking.item_id).to match(/\AUPS-[0-9a-f]{4}\z/)
    end
  end
end
