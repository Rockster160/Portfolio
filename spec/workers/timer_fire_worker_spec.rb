require "rails_helper"

RSpec.describe TimerFireWorker do
  let(:user) { create(:user) }

  it "skips archived timers" do
    timer = create(:timer, user: user, end_at: Time.current, archived_at: Time.current)
    expect { described_class.new.perform(timer.id) }.not_to change { timer.reload.fired_at }
  end

  it "skips already-fired timers" do
    timer = create(:timer, user: user, end_at: Time.current - 1.second, fired_at: Time.current)
    expect { described_class.new.perform(timer.id) }
      .not_to change { timer.reload.updated_at }
  end

  it "fires when due" do
    timer = create(:timer, user: user, started_at: 60.seconds.ago, end_at: 1.second.ago)
    allow(MonitorChannel).to receive(:broadcast_to)
    described_class.new.perform(timer.id)
    expect(timer.reload.fired_at).to be_present
  end

  it "re-enqueues itself when end_at drifted forward" do
    timer = create(:timer, user: user, started_at: Time.current, end_at: Time.current + 30.seconds)
    Sidekiq::Testing.fake! do
      TimerFireWorker.clear
      described_class.new.perform(timer.id)
      expect(TimerFireWorker.jobs.size).to eq(1)
      expect(timer.reload.fired_at).to be_nil
    end
  end
end
