RSpec.describe ExecutionCompactWorker, type: :worker do
  let(:user) { FactoryBot.create(:user, phone: "5559990001") }
  let(:task) { Task.create!(user: user, name: "Compact Subject", listener: "tell:cmp", code: "// noop", enabled: true) }

  def make_execution(task:, status:, started_at:, with_payload: true)
    payload = with_payload ? ExecutionPayload.create!(code: "x", input_data: {}, ctx: {}) : nil
    Execution.create!(
      user: user, task: task, status: status, auth_type: :trigger,
      started_at: started_at, finished_at: started_at + 0.1.seconds,
      payload: payload
    )
  end

  it "leaves the most recent N per (user, task, status) intact" do
    n = ExecutionCompactWorker::RETENTION_PER_GROUP
    base = 1.hour.ago
    (n + 5).times { |i| make_execution(task: task, status: :success, started_at: base + i.seconds) }

    expect { described_class.new.perform }.to change(ExecutionPayload, :count).by(-5)

    kept = task.executions.success.order(started_at: :desc).limit(n)
    expect(kept.all? { |e| e.payload_id.present? }).to be(true)

    older = task.executions.success.order(started_at: :desc).offset(n)
    expect(older.all? { |e| e.payload_id.nil? }).to be(true)
  end

  it "partitions retention by status so success and failed are kept independently" do
    n = ExecutionCompactWorker::RETENTION_PER_GROUP
    base = 1.hour.ago
    (n + 2).times { |i| make_execution(task: task, status: :success, started_at: base + i.seconds) }
    (n + 3).times { |i| make_execution(task: task, status: :failed,  started_at: base + (100 + i).seconds) }

    described_class.new.perform

    expect(task.executions.success.where.not(payload_id: nil).count).to eq(n)
    expect(task.executions.failed.where.not(payload_id: nil).count).to eq(n)
  end

  it "deletes the underlying ExecutionPayload rows it removes from executions" do
    n = ExecutionCompactWorker::RETENTION_PER_GROUP
    base = 1.hour.ago
    (n + 3).times { |i| make_execution(task: task, status: :success, started_at: base + i.seconds) }

    expect { described_class.new.perform }.to change(ExecutionPayload, :count).by(-3)
  end

  it "is a no-op when nothing exceeds the retention limit" do
    n = ExecutionCompactWorker::RETENTION_PER_GROUP
    n.times { |i| make_execution(task: task, status: :success, started_at: 1.hour.ago + i.seconds) }

    expect { described_class.new.perform }.not_to change(ExecutionPayload, :count)
  end
end
