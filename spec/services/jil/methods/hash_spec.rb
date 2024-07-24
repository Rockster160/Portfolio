RSpec.describe Jil::Methods::Hash do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:code) {
    <<-JIL
      n7c03 = Hash.new({
        bad73 = Keyval.new("foo", "bar")::Keyval
        o9d36 = Keyval.new("hi", "low")::Keyval
        l0033 = Keyval.new("k", "bai")::Keyval
      })::Hash
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  def expect_successful
    # load("/Users/rocco/.pryrc"); source_puts [ctx[:error_line], ctx[:error]].compact.join("\n")
    expect([ctx[:error_line], ctx[:error]].compact.join("\n")).to be_blank
  end

  # [Hash]
  #   #new(content(Keyval [Keyval.new]))
  #   #keyval(String Any)::Keyval
  #   .length::Numeric
  #   .merge(Hash)
  #   .keys::Array
  #   .dig(content(String [String.new]))::Any
  #   .get(String)::Any
  #   .set!(String "=" Any)
  #   .del!(String)
  #   .filter(content(["Key"::String "Value"::Any "Index"::Numeric)])
  #   .each(content(["Key"::String "Value"::Any "Index"::Numeric)])
  #   .map(content(["Key"::String "Value"::Any "Index"::Numeric)])::Array
  #   .any?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
  #   .none?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
  #   .all?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean

  context "#new" do
    it "stores the values as key/val pairs" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".length" do
    before do
      code << "r817a = n7c03.length()::Numeric"
    end

    it "returns the number of items in the hash" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :r817a])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
        r817a: { class: :Numeric, value: 3 },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".dig" do
    let(:code) {
      <<-JIL
        ia567 = Hash.new({
          xe891 = Keyval.new("foo", "bar")::Keyval
          x7802 = Keyval.new("sup", "boom")::Keyval
          m9851 = Keyval.keyHash("nest", {
            saf93 = Keyval.new("deep", "layer")::Keyval
            i47c8 = Keyval.keyHash("deeper", {
              o99f1 = Keyval.new("foo", "bar")::Keyval
              j3552 = Keyval.new("boom", "sup")::Keyval
            })::Keyval
          })::Keyval
        })::Hash
        d1a4f = ia567.dig({
          f5d8d = String.new("nest")::String
          e2883 = String.new("deeper")::String
          q3d8d = String.new("boom")::String
        })::Any
      JIL
    }

    it "returns the item at the bottom of the dig" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        xe891: { class: :Keyval, value: { foo: "bar" } },
        x7802: { class: :Keyval, value: { sup: "boom" } },
        saf93: { class: :Keyval, value: { deep: "layer" } },
        o99f1: { class: :Keyval, value: { foo: "bar" } },
        j3552: { class: :Keyval, value: { boom: "sup" } },
        i47c8: { class: :Keyval, value: {
          deeper: { foo: "bar", boom: "sup" },
        } },
        m9851: { class: :Keyval, value: {
          nest: {
            deep: "layer",
            deeper: { foo: "bar", boom: "sup" },
          }
        } },
        ia567: { class: :Hash, value: {
          foo: "bar",
          sup: "boom",
          nest: {
            deep: "layer",
            deeper: { foo: "bar", boom: "sup" },
          },
        } },
        f5d8d: { class: :String, value: "nest" },
        e2883: { class: :String, value: "deeper" },
        q3d8d: { class: :String, value: "boom" },
        d1a4f: { class: :Any, value: "sup" },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".merge" do
    before do
      code << <<-JIL
        je296 = Hash.new({
          q1634 = Keyval.new("new", "thing")::Keyval
          z20a3 = Keyval.new("some", "item")::Keyval
          a5129 = Keyval.new("cool", "stuff")::Keyval
        })::Hash
        h36ee = n7c03.merge(je296)::Hash
      JIL
    end

    it "merges two hashes together" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :q1634, :z20a3, :a5129, :je296, :h36ee])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
        q1634: { class: :Keyval, value: { new: "thing" } },
        z20a3: { class: :Keyval, value: { some: "item" } },
        a5129: { class: :Keyval, value: { cool: "stuff" } },
        je296: { class: :Hash, value: { new: "thing", some: "item", cool: "stuff" } },
        h36ee: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai", new: "thing", some: "item", cool: "stuff" } },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".keys" do
    before do
      code << "r817a = n7c03.keys()::Array"
    end

    it "returns the keys of the hash" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :r817a])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
        r817a: { class: :Array, value: ["foo", "hi", "k"] },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".get" do
    before do
      code << "r817a = n7c03.get(\"foo\")::Any"
    end

    it "returns the value of the specified key" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :r817a])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
        r817a: { class: :Any, value: "bar" },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".set!" do
    before do
      code << "r817a = n7c03.set!(\"foo\", \"bing\")::Hash\n"
      code << "r817b = n7c03.set!(\"stuff\", \"item\")::Hash\n"
    end

    it "sets the value of the specified key" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :r817a, :r817b])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bing", hi: "low", k: "bai", stuff: "item" } },
        r817a: { class: :Hash, value: { foo: "bing", hi: "low", k: "bai" } },
        r817b: { class: :Hash, value: { foo: "bing", hi: "low", k: "bai", stuff: "item" } },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".del!" do
    before do
      code << "r817a = n7c03.del!(\"foo\")::Hash\n"
    end

    it "removes the key/value pair from the hash by key" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :r817a])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { hi: "low", k: "bai"} },
        r817a: { class: :Hash, value: { hi: "low", k: "bai" } },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".filter" do
    before do
      code << <<-JIL
        hd4c1 = n7c03.filter({
          lf3d2 = Global.Index()::Numeric
          ee0d3 = Boolean.compare(lf3d2, ">", "0")::Boolean
        })::Hash
      JIL
    end

    it "returns the new hash based on passing conditions" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :lf3d2, :ee0d3, :hd4c1])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
        lf3d2: { class: :Numeric, value: 2 },
        ee0d3: { class: :Boolean, value: true },
        hd4c1: { class: :Hash, value: { hi: "low", k: "bai" } },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".map" do
    before do
      code << <<-JIL
        hd4c1 = n7c03.map({
          lf3d2 = Global.Index()::Numeric
          ee0d3 = Boolean.compare(lf3d2, ">", "0")::Boolean
        })::Array
      JIL
    end

    it "returns an array of the values from each block" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03, :lf3d2, :ee0d3, :hd4c1])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
        lf3d2: { class: :Numeric, value: 2 },
        ee0d3: { class: :Boolean, value: true },
        hd4c1: { class: :Array, value: [false, true, true] },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".any?" do
    before do
      code << <<-JIL
        hd4c1 = n7c03.any?({
          v3b3f = Global.Value()::String
          mb1a3 = v3b3f.length()::Numeric
          ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
        })::Boolean
      JIL
    end

    it "returns truthiness if there is any matching condition" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
        v3b3f: { class: :String, value: "bar" },
        mb1a3: { class: :Numeric, value: 3 },
        ee0d3: { class: :Boolean, value: true },
        hd4c1: { class: :Boolean, value: true },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".none?" do
    before do
      code << <<-JIL
        hd4c1 = n7c03.none?({
          v3b3f = Global.Value()::String
          mb1a3 = v3b3f.length()::Numeric
          ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
        })::Boolean
      JIL
    end

    it "returns truthiness if there is any matching condition" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
        v3b3f: { class: :String, value: "bar" },
        mb1a3: { class: :Numeric, value: 3 },
        ee0d3: { class: :Boolean, value: true },
        hd4c1: { class: :Boolean, value: false },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".all?" do
    before do
      code << <<-JIL
        hd4c1 = n7c03.all?({
          v3b3f = Global.Value()::String
          mb1a3 = v3b3f.length()::Numeric
          ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
        })::Boolean
      JIL
    end

    it "returns truthiness if there is any matching condition" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
        v3b3f: { class: :String, value: "bai" },
        mb1a3: { class: :Numeric, value: 3 },
        ee0d3: { class: :Boolean, value: true },
        hd4c1: { class: :Boolean, value: true },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".each" do
    before do
      code << <<-JIL
        hd4c1 = n7c03.each({
          v3b3f = Global.Value()::String
          mb1a3 = v3b3f.length()::Numeric
          ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
        })::Boolean
      JIL
    end

    it "returns truthiness if there is any matching condition" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { foo: "bar" } },
        o9d36: { class: :Keyval, value: { hi: "low" } },
        l0033: { class: :Keyval, value: { k: "bai" } },
        n7c03: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
        v3b3f: { class: :String, value: "bai" },
        mb1a3: { class: :Numeric, value: 3 },
        ee0d3: { class: :Boolean, value: true },
        hd4c1: { class: :Boolean, value: true },
      })
      expect(ctx[:output]).to eq([])
    end
  end
end
