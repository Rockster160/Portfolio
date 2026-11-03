require "rails_helper"

# A job that raises, in the error log by the job it was.
RSpec.describe SidekiqErrors do
  before { allow(SlackNotifier).to receive(:puts) }

  def boom
    RuntimeError.new("upstream 502").tap { |e| e.set_backtrace(["app/workers/sync_worker.rb:12"]) }
  end

  def context(klass, retry_count: nil)
    { job: { "class" => klass, "jid" => "abc123", "args" => [1, "x"], "retry_count" => retry_count }.compact }
  end

  it "records it under the job's class, with the run it was" do
    described_class.report(boom, context("SimpleFinSyncWorker", retry_count: 2))

    row = ErrorReport.last
    expect(row.section).to eq("sidekiq:SimpleFinSyncWorker")
    expect(row.error_class).to eq("RuntimeError")
    expect(row.message).to include("Job SimpleFinSyncWorker failed", "upstream 502")
    expect(row.extra).to include("jid" => "abc123", "retry" => 2, "args" => "[1,\"x\"]")
  end

  it "groups its retries as one failure, announced once" do
    allow(SlackNotifier).to receive(:deliver).and_return("#portfolio")

    3.times { |i| described_class.report(boom, context("SimpleFinSyncWorker", retry_count: i)) }

    expect(ErrorReport.distinct.count(:fingerprint)).to eq(1)
    expect(SlackNotifier).to have_received(:deliver).once
  end

  # Announcing a failure of the job that announces would queue another of it.
  it "records the alert job's own failures without announcing them" do
    allow(SlackNotifier).to receive(:deliver)

    described_class.report(boom, context("SlackWorker"))

    expect(ErrorReport.last.section).to eq("sidekiq:SlackWorker")
    expect(SlackNotifier).not_to have_received(:deliver)
  end

  it "never raises" do
    allow(ErrorReport).to receive(:record!).and_raise("gone")

    expect { described_class.report(boom, context("SlackWorker")) }.not_to raise_error
  end
end
