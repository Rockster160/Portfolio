RSpec.describe Jil::Executor do
  let(:user) { FactoryBot.create(:user, phone: "5559990002") }
  let(:code) {
    <<~JIL
      out = Global.print("hello")::String
    JIL
  }

  it "writes code/input_data/ctx to ExecutionPayload, not directly on Execution" do
    expect { described_class.call(user, code, { foo: "bar" }) }.to change(ExecutionPayload, :count).by(1)

    execution = Execution.last
    expect(execution.payload_id).to be_present
    expect(execution.code).to eq(code)
    expect(execution.input_data).to include("foo" => "bar")
    expect(execution.ctx).to include("output" => ["hello"])
  end

  it "does not run inline compaction on initialize" do
    11.times { described_class.call(user, code, {}) }

    expect(ExecutionPayload.count).to eq(11)
    expect(Execution.where.not(payload_id: nil).count).to eq(11)
  end

  it "exposes ctx-derived helpers through the payload" do
    described_class.call(user, code, {})
    execution = Execution.last
    expect(execution.output).to eq(["hello"])
    expect(execution.error).to be_nil
  end
end
