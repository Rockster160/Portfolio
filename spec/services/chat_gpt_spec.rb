RSpec.describe ChatGPT do
  describe ".short_names_from_orders" do
    it "returns [] for an empty input" do
      expect(ChatGPT.short_names_from_orders([])).to eq([])
    end

    it "sends one ask with all titles numbered in order, and aligns parsed lines back to the inputs" do
      titles = [
        "CELSIUS PEACH VIBE Sparkling White Peach, Sugar Free Energy Drink, 12 Fl Oz (Pack of 12)",
        "Sprite Zero, 12 fl oz, 12 Pack",
        "5Aplusreprap Ender 3 Hotend Upgraded Kit",
      ]
      captured_prompt = nil
      allow(ChatGPT).to receive(:ask) { |p|
        captured_prompt = p
        "Celsius Peach Vibe\nSprite Zero\nHotend Kit\n"
      }

      result = ChatGPT.short_names_from_orders(titles)
      expect(result).to eq(["Celsius Peach Vibe", "Sprite Zero", "Hotend Kit"])

      # Verifies a single batched call (not three) and that prompt contains all titles numbered.
      expect(ChatGPT).to have_received(:ask).once
      expect(captured_prompt).to include("1. CELSIUS", "2. Sprite Zero", "3. 5Aplusreprap")
    end

    it "tolerates numbered output (e.g. '1. Foo')" do
      allow(ChatGPT).to receive(:ask).and_return("1. Foo\n2. Bar\n3. Baz")
      expect(ChatGPT.short_names_from_orders(["a", "b", "c"])).to eq(["Foo", "Bar", "Baz"])
    end

    it "pads with nil when GPT returns fewer lines than titles" do
      allow(ChatGPT).to receive(:ask).and_return("Only One")
      expect(ChatGPT.short_names_from_orders(["a", "b", "c"])).to eq(["Only One", nil, nil])
    end

    it "rewrites 'filament' to 'Ink' (preserves the legacy single-name behavior)" do
      allow(ChatGPT).to receive(:ask).and_return("PLA Filament 1kg")
      expect(ChatGPT.short_names_from_orders(["whatever"])).to eq(["PLA Ink 1kg"])
    end
  end
end
