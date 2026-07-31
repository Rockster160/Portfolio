RSpec.describe ExecutionArchiveWorker, type: :worker do
  let(:user) { FactoryBot.create(:user, phone: "5559990101") }
  let(:task) {
    Task.create!(user: user, name: "Archive Subject", listener: "tell:arc", code: "// noop", enabled: true)
  }

  def make_execution(started_at:, status: :success, with_payload: false)
    payload = with_payload ? ExecutionPayload.create!(code: "x", input_data: {}, ctx: {}) : nil
    Execution.create!(
      user: user, task: task, status: status, auth_type: :trigger, trigger_scope: "tell",
      started_at: started_at, finished_at: started_at + 0.25.seconds, payload: payload
    )
  end

  it "moves executions older than the retention window into the archive" do
    old = make_execution(started_at: (described_class::RETENTION + 1.day).ago)
    recent = make_execution(started_at: 1.hour.ago)

    expect { described_class.new.perform }.to change(ExecutionArchive, :count).by(1)

    expect(Execution.exists?(old.id)).to be(false)
    expect(Execution.exists?(recent.id)).to be(true)
    expect(ExecutionArchive.exists?(old.id)).to be(true)
  end

  it "preserves the id and every timestamp exactly" do
    started = (described_class::RETENTION + 3.days).ago.change(usec: 0)
    execution = make_execution(started_at: started)
    finished = execution.finished_at

    described_class.new.perform
    archived = ExecutionArchive.find(execution.id)

    expect(archived.id).to eq(execution.id)
    expect(archived.started_at).to be_within(0.001.seconds).of(started)
    expect(archived.finished_at).to be_within(0.001.seconds).of(finished)
    expect(archived.created_at).to be_present
  end

  it "carries over the billing-relevant attributes" do
    execution = make_execution(started_at: (described_class::RETENTION + 1.day).ago, status: :failed)

    described_class.new.perform
    archived = ExecutionArchive.find(execution.id)

    expect(archived.user_id).to eq(user.id)
    expect(archived.task_id).to eq(task.id)
    expect(archived.status).to eq("failed")
    expect(archived.auth_type).to eq("trigger")
    expect(archived.trigger_scope).to eq("tell")
  end

  it "cleans up payloads belonging to archived executions" do
    make_execution(started_at: (described_class::RETENTION + 1.day).ago, with_payload: true)

    expect { described_class.new.perform }.to change(ExecutionPayload, :count).by(-1)
  end

  it "is idempotent - a second run neither duplicates nor raises" do
    make_execution(started_at: (described_class::RETENTION + 1.day).ago)
    described_class.new.perform

    expect { described_class.new.perform }.not_to change(ExecutionArchive, :count)
  end

  it "accepts a shorter retention for backfilling" do
    make_execution(started_at: 3.days.ago)

    expect { described_class.new.perform }.not_to change(ExecutionArchive, :count)
    expect { described_class.new.perform(1) }.to change(ExecutionArchive, :count).by(1)
  end

  it "leaves nothing stranded between the two tables" do
    5.times { |i| make_execution(started_at: (described_class::RETENTION + (i + 1).days).ago) }
    2.times { |i| make_execution(started_at: (i + 1).hours.ago) }

    described_class.new.perform

    expect(Execution.count + ExecutionArchive.count).to eq(7)
  end

  it "does not run while another archive pass holds the lock" do
    make_execution(started_at: (described_class::RETENTION + 1.day).ago)
    allow(User).to receive(:advisory_lock_exists?).with("execution_archive_worker").and_return(true)

    expect { described_class.new.perform }.not_to change(ExecutionArchive, :count)
  end
end
