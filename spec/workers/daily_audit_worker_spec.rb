require "rails_helper"

RSpec.describe DailyAuditWorker do
  let(:user) { User.me }

  before do
    allow(Rails.env).to receive(:production?).and_return(true)
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

  # The dev box runs the same cron schedule against its own database, so
  # `already_ran?` sees nothing and lets a second audit through — one that
  # publishes into the PRODUCTION thread, because the Mac reports to a single
  # callback. Prod 4935, 5040 and 5100 are the three that got out that way.
  context "when it is not production" do
    before { allow(Rails.env).to receive(:production?).and_return(false) }

    it "posts nothing" do
      counted = -> { ByteDailyAudit.conversation(user).byte_messages.count }

      expect { described_class.new.perform }.not_to change(counted, :call)
    end

    it "does not run the audit at all" do
      expect(ByteDailyAudit).not_to receive(:run!)

      described_class.new.perform
    end
  end

  # The by-hand path goes straight to ByteDailyAudit and is how a run gets
  # kicked from a console; only the SCHEDULED path is what fires twice.
  it "leaves kick! usable outside production" do
    allow(Rails.env).to receive(:production?).and_return(false)

    counted = -> { ByteDailyAudit.conversation(user).byte_messages.count }

    expect { ByteDailyAudit.kick!(user) }.to change(counted, :call).by(1)
  end
end
