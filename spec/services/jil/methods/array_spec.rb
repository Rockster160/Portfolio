RSpec.describe Jil::Methods::Hash do
  include ActiveJob::TestHelper
  let(:execute) { ::Jil::Executor.call(user, code, input_data) }
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:code) {
    <<-JIL
      r5ee3 = Array.new({
        rb9ed = String.new("Hello, World!")::String
        ydfcd = Boolean.new(false)::Boolean
        xfaed = Numeric.new(47)::Numeric
      })::Array
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  def expect_successful
    load("/Users/rocco/.pryrc"); source_puts [ctx[:error_line], ctx[:error]].compact.join("\n")
    expect([ctx[:error_line], ctx[:error]].compact.join("\n")).to be_blank
  end

  # [Array]
  #   #new(content)
  #   #from_length(Numeric)
  #   .length::Numeric
  #   .combine(Array)
  #   .get(Numeric)::Any
  #   .set!(Numeric "=" Any)
  #   .del!(Numeric)
  #   .dig(content(String|Numeric [String.new Numeric.new]))::Any
  #   .pop!::Any
  #   .push!(Any)
  #   .shift!::Any
  #   .unshift!(Any)
  #   .each(content(["Object"::Any "Index"::Numeric]))
  #   .map(content(["Object"::Any "Index"::Numeric]))
  #   .find(content(["Object"::Any "Index"::Numeric]))::Any
  #   .any?(content(["Object"::Any "Index"::Numeric]))::Boolean
  #   .none?(content(["Object"::Any "Index"::Numeric]))::Boolean
  #   .all?(content(["Object"::Any "Index"::Numeric]))::Boolean
  #   .sort_by(content(["Object"::Any "Index"::Numeric]))
  #   .sort_by!(content(["Object"::Any "Index"::Numeric]))
  #   .sort(["Ascending" "Descending" "Reverse" "Random"])
  #   .sort!(["Ascending" "Descending" "Reverse" "Random"])
  #   .shuffle::Any
  #   .sample::Any
  #   .min::Any
  #   .max::Any
  #   .sum::Any
  #   .join(String)::String

  context "#new" do
    it "stores the items" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        rb9ed: { class: :String, value: "Hello, World!" },
        ydfcd: { class: :Boolean, value: false },
        xfaed: { class: :Numeric, value: 47 },
        r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "#from_length" do
    let(:code) { "r5ee3 = Array.from_length(5)::Array" }

    it "creates an array of nil of the desired length" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        r5ee3: { class: :Array, value: [nil, nil, nil, nil, nil] },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".length" do
    before do
      code << "r817a = r5ee3.length()::Numeric"
    end

    it "returns the number of items in the hash" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        rb9ed: { class: :String, value: "Hello, World!" },
        ydfcd: { class: :Boolean, value: false },
        xfaed: { class: :Numeric, value: 47 },
        r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
        r817a: { class: :Numeric, value: 3 },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context ".dig" do
    let(:code) {
      <<-JIL
        r5ee3 = Array.new({
          rb9ed = String.new("Hello, World!")::String
          ydfcd = Boolean.new(false)::Boolean
          xfaed = Numeric.new(47)::Numeric
        })::Array
        q877f = Array.new({
          t6996 = String.new("Hello, World!")::String
          n0dfd = String.new("Goodbye, World!")::String
        })::Array
        y14ae = Array.new({
          z085d = String.new("Food")::String
          kf5ff = String.new("Bar")::String
          w6f77 = String.new("Ting")::String
          t3c68 = Hash.new({
            g79cb = Keyval.new("foo", "bar")::Keyval
            td346 = Keyval.new("thing", "sup")::Keyval
            o06eb = Keyval.new("hello", "world")::Keyval
            pa52a = Keyval.new("arr", q877f)::Keyval
          })::Hash
        })::Array
        p363f = y14ae.dig({
          wd697 = Numeric.new(3)::Numeric
          b26f5 = String.new("arr")::String
          d55ec = Numeric.new(0)::Numeric
        })::Any
      JIL
    }

    it "returns the item at the bottom of the dig" do
      expect_successful
      expect(ctx.dig(:vars)).to match_hash({
        rb9ed: { class: :String, value: "Hello, World!" },
        ydfcd: { class: :Boolean, value: false },
        xfaed: { class: :Numeric, value: 47 },
        r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
        t6996: { class: :String, value: "Hello, World!" },
        n0dfd: { class: :String, value: "Goodbye, World!" },
        q877f: { class: :Array, value: ["Hello, World!", "Goodbye, World!"] },
        z085d: { class: :String, value: "Food" },
        kf5ff: { class: :String, value: "Bar" },
        w6f77: { class: :String, value: "Ting" },
        g79cb: { class: :Keyval, value: { foo: "bar" } },
        td346: { class: :Keyval, value: { thing: "sup" } },
        o06eb: { class: :Keyval, value: { hello: "world" } },
        pa52a: { class: :Keyval, value: { arr: ["Hello, World!", "Goodbye, World!"] } },
        t3c68: { class: :Hash, value: { foo: "bar", thing: "sup", hello: "world", arr: ["Hello, World!", "Goodbye, World!"] } },
        y14ae: { class: :Array, value: ["Food", "Bar", "Ting", {"foo"=>"bar", "thing"=>"sup", "hello"=>"world", "arr"=>["Hello, World!", "Goodbye, World!"]}] },
        wd697: { class: :Numeric, value: 3 },
        b26f5: { class: :String, value: "arr" },
        d55ec: { class: :Numeric, value: 0 },
        p363f: { class: :Any, value: "Hello, World!" }
      })
      expect(ctx[:output]).to eq([])
    end
  end
  #
  # context ".merge" do
  #   before do
  #     code << <<-JIL
  #       je296 = Hash.new({
  #         q1634 = Keyval.new("new", "thing")::Keyval
  #         z20a3 = Keyval.new("some", "item")::Keyval
  #         a5129 = Keyval.new("cool", "stuff")::Keyval
  #       })::Hash
  #       h36ee = r5ee3.merge(je296)::Hash
  #     JIL
  #   end
  #
  #   it "merges two hashes together" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
  #       q1634: { class: :Keyval, value: { new: "thing" } },
  #       z20a3: { class: :Keyval, value: { some: "item" } },
  #       a5129: { class: :Keyval, value: { cool: "stuff" } },
  #       je296: { class: :Hash, value: { new: "thing", some: "item", cool: "stuff" } },
  #       h36ee: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai", new: "thing", some: "item", cool: "stuff" } },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".keys" do
  #   before do
  #     code << "r817a = r5ee3.keys()::Array"
  #   end
  #
  #   it "returns the keys of the hash" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
  #       r817a: { class: :Array, value: ["foo", "hi", "k"] },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".get" do
  #   before do
  #     code << "r817a = r5ee3.get(\"foo\")::Any"
  #   end
  #
  #   it "returns the value of the specified key" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai" } },
  #       r817a: { class: :Any, value: "bar" },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".set!" do
  #   before do
  #     code << "r817a = r5ee3.set!(\"foo\", \"bing\")::Hash\n"
  #     code << "r817b = r5ee3.set!(\"stuff\", \"item\")::Hash\n"
  #   end
  #
  #   it "sets the value of the specified key" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bing", hi: "low", k: "bai", stuff: "item" } },
  #       r817a: { class: :Hash, value: { foo: "bing", hi: "low", k: "bai" } },
  #       r817b: { class: :Hash, value: { foo: "bing", hi: "low", k: "bai", stuff: "item" } },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".del!" do
  #   before do
  #     code << "r817a = r5ee3.del!(\"foo\")::Hash\n"
  #   end
  #
  #   it "removes the key/value pair from the hash by key" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { hi: "low", k: "bai"} },
  #       r817a: { class: :Hash, value: { hi: "low", k: "bai" } },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".filter" do
  #   before do
  #     code << <<-JIL
  #       hd4c1 = r5ee3.filter({
  #         lf3d2 = Global.Index()::Numeric
  #         ee0d3 = Boolean.compare(lf3d2, ">", "0")::Boolean
  #       })::Hash
  #     JIL
  #   end
  #
  #   it "returns the new hash based on passing conditions" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
  #       lf3d2: { class: :Numeric, value: 2 },
  #       ee0d3: { class: :Boolean, value: true },
  #       hd4c1: { class: :Hash, value: { hi: "low", k: "bai" } },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".map" do
  #   before do
  #     code << <<-JIL
  #       hd4c1 = r5ee3.map({
  #         lf3d2 = Global.Index()::Numeric
  #         ee0d3 = Boolean.compare(lf3d2, ">", "0")::Boolean
  #       })::Array
  #     JIL
  #   end
  #
  #   it "returns an array of the values from each block" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
  #       lf3d2: { class: :Numeric, value: 2 },
  #       ee0d3: { class: :Boolean, value: true },
  #       hd4c1: { class: :Array, value: [false, true, true] },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".any?" do
  #   before do
  #     code << <<-JIL
  #       hd4c1 = r5ee3.any?({
  #         v3b3f = Global.Value()::String
  #         mb1a3 = v3b3f.length()::Numeric
  #         ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
  #       })::Boolean
  #     JIL
  #   end
  #
  #   it "returns truthiness if there is any matching condition" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
  #       v3b3f: { class: :String, value: "bar" },
  #       mb1a3: { class: :Numeric, value: 3 },
  #       ee0d3: { class: :Boolean, value: true },
  #       hd4c1: { class: :Boolean, value: true },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".none?" do
  #   before do
  #     code << <<-JIL
  #       hd4c1 = r5ee3.none?({
  #         v3b3f = Global.Value()::String
  #         mb1a3 = v3b3f.length()::Numeric
  #         ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
  #       })::Boolean
  #     JIL
  #   end
  #
  #   it "returns truthiness if there is any matching condition" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
  #       v3b3f: { class: :String, value: "bar" },
  #       mb1a3: { class: :Numeric, value: 3 },
  #       ee0d3: { class: :Boolean, value: true },
  #       hd4c1: { class: :Boolean, value: false },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".all?" do
  #   before do
  #     code << <<-JIL
  #       hd4c1 = r5ee3.all?({
  #         v3b3f = Global.Value()::String
  #         mb1a3 = v3b3f.length()::Numeric
  #         ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
  #       })::Boolean
  #     JIL
  #   end
  #
  #   it "returns truthiness if there is any matching condition" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
  #       v3b3f: { class: :String, value: "bai" },
  #       mb1a3: { class: :Numeric, value: 3 },
  #       ee0d3: { class: :Boolean, value: true },
  #       hd4c1: { class: :Boolean, value: true },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".each" do
  #   before do
  #     code << <<-JIL
  #       hd4c1 = r5ee3.each({
  #         v3b3f = Global.Value()::String
  #         mb1a3 = v3b3f.length()::Numeric
  #         ee0d3 = Boolean.compare(mb1a3, ">", "2")::Boolean
  #       })::Boolean
  #     JIL
  #   end
  #
  #   it "returns truthiness if there is any matching condition" do
  #     expect_successful
  #     expect(ctx.dig(:vars)).to match_hash({
  # rb9ed: { class: :String, value: "Hello, World!" },
  # ydfcd: { class: :Boolean, value: false },
  # xfaed: { class: :Numeric, value: 47 },
  # r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       bad73: { class: :Keyval, value: { foo: "bar" } },
  #       o9d36: { class: :Keyval, value: { hi: "low" } },
  #       l0033: { class: :Keyval, value: { k: "bai" } },
  #       r5ee3: { class: :Hash, value: { foo: "bar", hi: "low", k: "bai"} },
  #       v3b3f: { class: :String, value: "bai" },
  #       mb1a3: { class: :Numeric, value: 3 },
  #       ee0d3: { class: :Boolean, value: true },
  #       hd4c1: { class: :Boolean, value: true },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
end
