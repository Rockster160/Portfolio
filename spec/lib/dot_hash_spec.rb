RSpec.describe DotHash do
  describe ".from" do
    it "builds a DotHash from a hash" do
      hash = { "a" => { "b" => 1 }, "c" => 2 }
      dot = DotHash.from(hash)

      expect(dot).to be_a(DotHash)
      expect(dot[:a]).to be_a(DotHash)
      expect(dot.a.b).to eq(1)
      expect(dot[:c]).to eq(2)
    end
  end

  describe ".from_branch" do
    it "splits keys on unescaped dots into nested hashes" do
      # sample flat hash with escaped dots
      flat = { "event.dot\\.data.custom.nested_key" => "fuzzy_val thing" }
      nested = DotHash.from_branch(flat)

      expected = {
        event: {"dot.data": { custom: { nested_key: "fuzzy_val thing" } }}
      }

      expect(nested).to eq(expected)
    end
  end

  describe ".every_stream" do
    it "returns key paths and values for flattened hash" do
      flat = { foo: { bar: 1, baz: { qux: 2 } } }
      streams = DotHash.every_stream(flat)

      expect(streams).to match_array([
        ["foo", "bar", 1],
        ["foo", "baz", "qux", 2]
      ])
    end
  end

  describe "#initialize and method access" do
    it "symbolizes keys and wraps nested hashes" do
      hash = { "x" => { "y" => 5 } }
      dot = DotHash.new(hash)

      expect(dot.keys).to include(:x)
      expect(dot.x).to be_a(DotHash)
      expect(dot.x.y).to eq(5)
    end
  end

  describe "#branches" do
    context "with nested hashes" do
      it "returns flat key paths" do
        hash = { foo: { bar: 1 } }
        dot = DotHash.new(hash)

        expect(dot.branches).to eq({ "foo.bar" => 1 })
      end

      it "maps empty hashes to empty strings" do
        hash = { foo: {} }
        dot = DotHash.new(hash)

        expect(dot.branches).to eq({ "foo" => "" })
      end
    end

    context "with arrays" do
      it "indexes array elements in keys" do
        hash = { arr: [10, 20] }
        dot = DotHash.new(hash)

        expect(dot.branches).to eq({ "arr.0" => 10, "arr.1" => 20 })
      end
    end
  end

  describe "#every_branch" do
    it "wraps each branch into its own nested structure" do
      hash = { foo: { bar: 3 } }
      dot = DotHash.new(hash)
      branches = dot.every_branch

      expect(branches.size).to eq(1)
      expect(branches.first).to be_a(DotHash)
      expect(branches.first.foo.bar).to eq(3)
    end
  end

  describe "#every_stream instance method" do
    it "mirrors .every_stream on instances" do
      dot = DotHash.new(a: { b: 7 })

      expect(dot.every_stream).to eq([["a", "b", 7]])
    end
  end
end
