RSpec.describe AmazonItemCatalog do
  describe ".get / .set survives a JSON round-trip" do
    # SafeJsonSerializer parses with `symbolize_names: true`, so any hash that's
    # been persisted to user_caches comes back symbol-keyed. The catalog keys
    # are ASINs (strings) - this guards against the regression where set wrote
    # under "B0XYZ" but get-after-reload looked up under :B0XYZ and missed.
    it "looks up an ASIN written before persistence" do
      allow(MeCache).to receive(:get).with(described_class::CACHE_KEY).and_return({})
      allow(MeCache).to receive(:set)

      described_class.set("B0FDLFSZ1S", name: "Genie Bags")

      # Simulate the persistence round-trip: cache is read back with symbolized keys.
      allow(MeCache).to receive(:get).with(described_class::CACHE_KEY).and_return(
        { B0FDLFSZ1S: { name: "Genie Bags" } },
      )

      expect(described_class.get("B0FDLFSZ1S")).to eq(name: "Genie Bags")
    end

    it "preserves a manual rename across a simulated reload" do
      stored = {}
      allow(MeCache).to receive(:get).with(described_class::CACHE_KEY) { stored }
      allow(MeCache).to receive(:set) { |_, val|
        # Real Rails round-trip would JSON-encode + symbol-decode here.
        stored.replace(JSON.parse(JSON.dump(val), symbolize_names: true))
      }

      described_class.set("B0FDLFSZ1S", name: "Sprite")        # initial / auto-named
      described_class.set("B0FDLFSZ1S", name: "Sprite Zero")   # user rename via dashboard

      expect(described_class.get("B0FDLFSZ1S")[:name]).to eq("Sprite Zero")
    end
  end
end
