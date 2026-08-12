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

  it "is registered on the cron schedule" do
    schedule = Rails.root.join("config/initializers/sidekiq_cron.rb").read

    expect(schedule).to include("DailyAuditWorker")
    expect(schedule).to include("daily_6am")
    expect(schedule).to include(%(daily_6am = "0 6 * * * MST"))
  end
end
