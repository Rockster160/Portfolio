require "rails_helper"

RSpec.describe DailyAuditWorker do
  let(:user) { User.me }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ByteLocal).to receive(:reset_claude_session).and_return(true)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  context "when the Mac is up" do
    before { allow(ByteLocal).to receive(:awake?).and_return(true) }

    it "runs the audit" do
      expect(ByteDailyAudit).to receive(:run!).with(user)

      described_class.new.perform
    end

    it "does not reschedule itself" do
      expect(described_class).not_to receive(:perform_in)

      described_class.new.perform
    end
  end

  # The one scheduled job whose work happens on a machine that sleeps. A message
  # posted at a sleeping Mac isn't deferred - it's a failed bubble in the thread.
  context "when the Mac is asleep" do
    before { allow(ByteLocal).to receive(:awake?).and_return(false) }

    it "posts nothing at all" do
      expect(ByteDailyAudit).not_to receive(:run!)

      described_class.new.perform
    end

    it "tries again later, carrying the attempt count" do
      expect(described_class).to receive(:perform_in).with(described_class::RETRY_EVERY, 1)

      described_class.new.perform
    end

    it "keeps counting up across attempts" do
      expect(described_class).to receive(:perform_in).with(described_class::RETRY_EVERY, 5)

      described_class.new.perform(4)
    end

    it "gives up rather than retrying forever" do
      expect(described_class).not_to receive(:perform_in)

      described_class.new.perform(described_class::MAX_ATTEMPTS - 1)
    end

    # A missing report reads exactly like a quiet day, and those are the two
    # things it most matters to be able to tell apart.
    it "says in the thread that it never ran" do
      described_class.new.perform(described_class::MAX_ATTEMPTS - 1)
      posted = ByteDailyAudit.conversation(user).byte_messages.order(:created_at).last

      expect(posted.body).to include("never came up")
      expect(posted.body).to include("this is not a quiet day")
      expect(posted.metadata["daily_audit_skipped"]).to be(true)
    end
  end

  it "is registered on the cron schedule" do
    schedule = Rails.root.join("config/initializers/sidekiq_cron.rb").read

    expect(schedule).to include("DailyAuditWorker")
    expect(schedule).to include("daily_10pm")
    expect(schedule).to include(%(daily_10pm = "0 22 * * * MST"))
  end
end
