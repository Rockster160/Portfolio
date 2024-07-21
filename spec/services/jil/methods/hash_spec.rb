RSpec.describe Jil::Methods::String do
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
    expect([ctx[:error_line], ctx[:error]].compact.join("\n")).to be_blank
  end

  # [Hash]
  #   #new(content(Keyval [Keyval.new]))
  #   #keyval(String Any)::Keyval
  #   .length::Numeric
  #   .dig(content(String [String.new]))::Any
  #   .merge(Hash)
  #   .keys::Array
  #   .get(String)::Any
  #   .set(String "=" Any)
  #   .del(String)
  #   .each(content(["Key"::String "Value"::Any "Index"::Numeric)])
  #   .map(content(["Key"::String "Value"::Any "Index"::Numeric)])::Array
  #   .any?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
  #   .none?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
  #   .all?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean

  context "#new" do
    it "stores the string" do
      expect_successful
      expect(ctx[:vars].keys).to eq([:bad73, :o9d36, :l0033, :n7c03])
      expect(ctx.dig(:vars)).to match_hash({
        bad73: { class: :Keyval, value: { "foo": "bar" } },
        o9d36: { class: :Keyval, value: { "hi": "low" } },
        l0033: { class: :Keyval, value: { "k": "bai" } },
        n7c03: { class: :Hash, value: { "foo": "bar", "hi": "low", "k": "bai" } },
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
        bad73: { class: :Keyval, value: { "foo": "bar" } },
        o9d36: { class: :Keyval, value: { "hi": "low" } },
        l0033: { class: :Keyval, value: { "k": "bai" } },
        n7c03: { class: :Hash, value: { "foo": "bar", "hi": "low", "k": "bai" } },
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
        xe891: { class: :Keyval, value: { "foo": "bar" } },
        x7802: { class: :Keyval, value: { "sup": "boom" } },
        saf93: { class: :Keyval, value: { "deep": "layer" } },
        o99f1: { class: :Keyval, value: { "foo": "bar" } },
        j3552: { class: :Keyval, value: { "boom": "sup" } },
        i47c8: { class: :Keyval, value: {
          "deeper": { "foo": "bar", "boom": "sup" },
        } },
        m9851: { class: :Keyval, value: {
          "nest": {
            "deep": "layer",
            "deeper": { "foo": "bar", "boom": "sup" },
          }
        } },
        ia567: { class: :Hash, value: {
          "foo": "bar",
          "sup": "boom",
          "nest": {
            "deep": "layer",
            "deeper": { "foo": "bar", "boom": "sup" },
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
end
