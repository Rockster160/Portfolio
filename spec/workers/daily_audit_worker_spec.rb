require "rails_helper"

RSpec.describe DailyAuditWorker do
  let(:user) { User.me }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ByteLocal).to receive(:reset_claude_session).and_return(true)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  it "runs the audit" do
    expect(ByteDailyAudit).to receive(:run!).with(user)

    described_class.new.perform
  end

  it "posts the prompt into the thread" do
    expect { described_class.new.perform }.to change { ByteDailyAudit.conversation(user).byte_messages.count }.by(1)
  end

  # Ordinarily enqueued by the briefing turn; the cron entry is the backstop for
  # a day that never had one. Either way `already_ran?` is what stops a second
  # report, so the same worker running twice has to be harmless.
  it "posts nothing on a second run the same day" do
    described_class.new.perform

    counted = -> { ByteDailyAudit.conversation(user).byte_messages.count }

    expect { described_class.new.perform }.not_to change(counted, :call)
  end
end
