require "rails_helper"

RSpec.describe Jil::Schedule do
  let(:user) { create(:user) }

  before do
    allow(::Jil).to receive(:trigger).and_return(true)
  end

  def schedule!(execute_at)
    ScheduledTrigger.create!(user: user, trigger: "monitor", execute_at: execute_at, data: {})
  end

  def broadcasts
    have_received(:trigger).with(user, :schedule, any_args)
  end

  describe ".broadcast" do
    it "stays quiet when an immediate trigger is created or completed" do
      schedule = schedule!(Time.current)

      described_class.broadcast(schedule, :created)
      described_class.broadcast(schedule, :completed)

      expect(::Jil).not_to broadcasts
    end

    it "still announces an immediate trigger being cancelled" do
      described_class.broadcast(schedule!(Time.current), :canceled)

      expect(::Jil).to broadcasts.once
    end

    it "announces a timed trigger being created and completed" do
      schedule = schedule!(1.hour.from_now)

      described_class.broadcast(schedule, :created)
      described_class.broadcast(schedule, :completed)

      expect(::Jil).to broadcasts.twice
    end
  end

  describe "running an immediate trigger" do
    it "does not set off the schedule listeners" do
      schedule!(1.second.ago)

      JilRunnerWorker.new.execute_continually(user)

      expect(::Jil).to have_received(:trigger).with(user, "monitor", any_args)
      expect(::Jil).not_to broadcasts
    end
  end
end
