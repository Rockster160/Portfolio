RSpec.describe AmazonOrder do
  describe "serialize/reload round-trip" do
    # Regression: `serialize` includes the computed, read-only `url` field, and
    # `save` persists that hash to the cache. Reloading must not blow up trying
    # to call the non-existent `url=` writer.
    it "rebuilds from its own serialized hash without raising" do
      order = described_class.new(
        carrier:         :ups,
        tracking_number: "1Z16D56V0310080972",
        source:          "NINGBO DEYI SAM",
        order_id:        "UPS",
        item_id:         "1Z16D56V0310080972",
        name:            "NINGBO DEYI SAM",
      )

      data = order.serialize
      expect(data).to have_key(:url)

      rebuilt = nil
      expect { rebuilt = described_class.new(data) }.not_to raise_error
      expect(rebuilt.carrier).to eq(:ups)
      expect(rebuilt.tracking_number).to eq("1Z16D56V0310080972")
      expect(rebuilt.url).to eq("https://www.ups.com/track?tracknum=1Z16D56V0310080972")
    end

    it "rebuilds an Amazon row (string carrier from JSON) back to a symbol" do
      rebuilt = described_class.new(described_class.new(item_id: "B0GF24P6J3").serialize.merge(carrier: "amazon"))

      expect(rebuilt.carrier).to eq(:amazon)
      expect(rebuilt.url).to eq("https://www.amazon.com/dp/B0GF24P6J3")
    end
  end

  describe "#url" do
    it "is the carrier tracking page when a non-Amazon item has a tracking number" do
      order = described_class.new(carrier: :usps, tracking_number: "9200190267338000065163052")
      expect(order.url).to eq("https://tools.usps.com/go/TrackConfirmAction?tLabels=9200190267338000065163052")
    end

    it "is nil for a non-Amazon item with no tracking number (no bogus Amazon link)" do
      order = described_class.new(carrier: :ups, item_id: "UPS-abcd", source: "NINGBO")
      expect(order.url).to be_nil
    end
  end
end
