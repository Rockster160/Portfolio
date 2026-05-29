RSpec.describe Jil::Methods::Tokenizing do
  include ActiveJob::TestHelper

  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  describe "#breakdown" do
    let(:code) {
      <<~'JIL'
        broken = Tokenizing.breakdown("event:name::food")::Hash
      JIL
    }

    it "returns the structured Breaker hash" do
      expect_successful_jil
      expect(ctx[:vars][:broken][:value].deep_symbolize_keys).to eq(
        keys: { event: { contains: [{ keys: { name: { exact: ["food"] } } }] } },
      )
    end
  end

  describe "#parse" do
    let(:code) {
      <<~'JIL'
        parsed = Tokenizing.parse("person:chelsea:value")::Hash
      JIL
    }

    it "returns the literal nested data hash" do
      expect_successful_jil
      expect(ctx[:vars][:parsed][:value].deep_symbolize_keys).to eq(person: { chelsea: "value" })
    end
  end

  describe "#match?" do
    let(:code) {
      <<~'JIL'
        data = Hash.new({
          k1 = Keyval.new("name", "food")::Keyval
        })::Hash
        matched = Tokenizing.match?("name::food", data)::Boolean
        missed = Tokenizing.match?("name::drink", data)::Boolean
      JIL
    }

    it "returns true/false based on whether the query matches" do
      expect_successful_jil
      expect(ctx[:vars][:matched][:value]).to be(true)
      expect(ctx[:vars][:missed][:value]).to be(false)
    end
  end

  describe "#matchData" do
    let(:code) {
      <<~'JIL'
        data = Hash.new({
          k1 = Keyval.new("tell", "take 180 mg")::Keyval
        })::Hash
        captures = Tokenizing.matchData("tell:/(?<amount>\\d+)\\s*mg/", data)::Hash
      JIL
    }

    it "exposes regex named_captures" do
      expect_successful_jil
      result = ctx[:vars][:captures][:value].deep_symbolize_keys
      expect(result[:named_captures][:amount]).to eq("180")
      expect(result[:match_list]).to include("180 mg")
    end
  end
end
