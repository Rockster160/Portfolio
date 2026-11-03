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

  it "moves executions older than the retention window into the archive, intact" do
    started = (described_class::RETENTION + 3.days).ago.change(usec: 0)
    old = make_execution(started_at: started, status: :failed, with_payload: true)
    older = make_execution(started_at: (described_class::RETENTION + 5.days).ago)
    recent = make_execution(started_at: 1.hour.ago)

    expect { described_class.new.perform }.to(
      change(ExecutionArchive, :count).by(2).and(change(ExecutionPayload, :count).by(-1)),
    )

    expect(Execution.exists?(old.id)).to be(false)
    expect(Execution.exists?(older.id)).to be(false)
    expect(Execution.exists?(recent.id)).to be(true)
    expect(Execution.count + ExecutionArchive.count).to eq(3)

    archived = ExecutionArchive.find(old.id)
    expect(archived.started_at).to be_within(0.001.seconds).of(started)
    expect(archived.finished_at).to be_within(0.001.seconds).of(old.finished_at)
    expect(archived.created_at).to be_present
    expect(archived).to have_attributes(
      user_id: user.id, task_id: task.id, status: "failed", auth_type: "trigger", trigger_scope: "tell",
    )
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

  it "does not run while another archive pass holds the lock" do
    make_execution(started_at: (described_class::RETENTION + 1.day).ago)
    allow(User).to receive(:advisory_lock_exists?).with("execution_archive_worker").and_return(true)

    expect { described_class.new.perform }.not_to change(ExecutionArchive, :count)
  end
end
