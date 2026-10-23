require "rails_helper"

RSpec.describe "log_event tool" do
  let(:user) { create(:user) }
  let(:ctx) { Buddy::ToolContext.new(user) }
  let(:tool) { Buddy::Tools[:log_event] }

  before { allow(ActionEventNotifier).to receive(:notify) }

  def log(**payload)
    tool[:confirm].call(payload, ctx)
    tool[:execute].call(payload, ctx)
    user.action_events.last
  end

  it "logs it now when no time is given" do
    freeze_time {
      expect(log(name: "Coffee").timestamp).to eq(Time.current)
    }
  end

  # "I got sick yesterday morning": whatever listens for the event reads its
  # time as when it happened.
  it "logs it when it happened, given an earlier time" do
    at = 1.day.ago.change(hour: 8, min: 0, sec: 0)

    expect(log(name: "Sick", at: at).timestamp).to eq(at)
  end

  it "refuses a time that hasn't come yet" do
    expect { tool[:confirm].call({ name: "Lunch", at: 2.hours.from_now }, ctx) }.to raise_error(/hasn't happened/)
  end
end
