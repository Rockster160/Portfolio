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

  # A camera frame reaches Jil as ~500KB of base64 sitting in a var, so what
  # gets done with vars stopped being free. `store_progress` writes
  # `ctx.except(:vars)` and `broadcast!` sends five named keys — neither carries
  # a value. Including vars in either would write half a megabyte into
  # execution_payloads and push it down the socket on EVERY snapshot request,
  # 32 times over, since execute_line broadcasts per line.
  it "keeps var values out of the stored payload and off the socket" do
    big = "x" * 200_000
    allow_any_instance_of(Jil::Methods::Global).to receive(:request).and_return(
      code: 200, body: { "frame" => big },
    )
    broadcasts = []
    allow(TasksChannel).to receive(:send_to) { |_u, _uuid, data| broadcasts << data }

    described_class.call(user, <<~'JIL', {})
      res = Global.request("GET", "http://example.test", {}, {})::Hash
      huge = res.get("frame")::String
      out = Global.return("done")::String
    JIL

    payload = Execution.last.payload
    expect(payload.code.bytesize).to be < 1_000
    expect(payload.ctx.to_json).not_to include(big)
    expect(broadcasts.map(&:to_json).join).not_to include(big)
  end

  it "exposes ctx-derived helpers through the payload" do
    described_class.call(user, code, {})
    execution = Execution.last
    expect(execution.output).to eq(["hello"])
    expect(execution.error).to be_nil
  end
end
