require "rails_helper"

RSpec.describe Jil::Methods::Schedule, "#cancel_by_tag" do
  let(:user) { User.me }

  def create_schedule(tag, execute_at: 2.hours.from_now)
    ::Jil::Schedule.add_schedule(user, execute_at, "whisper-notify", { tag: tag, title: "Test", body: "" })
    user.scheduled_triggers.not_started.where(trigger: "whisper-notify").order(created_at: :desc).first!
  end

  it "cancels all pending schedules with matching trigger and tag" do
    s1 = create_schedule("whisper-outside")
    s2 = create_schedule("whisper-outside")
    s3 = create_schedule("whisper-napping") # different tag

    code = <<~JIL
      result = Schedule.cancelByTag("whisper-notify", "whisper-outside")::Boolean
    JIL

    Jil::Executor.call(user, code)

    expect(ScheduledTrigger.exists?(s1.id)).to be false
    expect(ScheduledTrigger.exists?(s2.id)).to be false
    expect(ScheduledTrigger.exists?(s3.id)).to be true
  end

  it "does not error when no matching schedules exist" do
    code = <<~JIL
      result = Schedule.cancelByTag("whisper-notify", "nonexistent")::Boolean
    JIL

    expect { Jil::Executor.call(user, code) }.not_to raise_error
  end
end
