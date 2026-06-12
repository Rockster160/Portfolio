require "rails_helper"

RSpec.describe Jil::Methods::Schedule, "#search" do
  let(:user) { User.me }

  def create_schedule(trigger, execute_at:, data: {})
    ::Jil::Schedule.add_schedule(user, execute_at, trigger, data)
    user.scheduled_triggers.not_started.where(trigger: trigger).order(created_at: :desc).first!
  end

  def run(code)
    Jil::Executor.call(user, code).ctx[:vars]
  end

  it "returns pending schedules matching trigger without raising on Array#page" do
    s_now = create_schedule("whisper-hungry-check", execute_at: 1.hour.from_now)
    s_later = create_schedule("whisper-hungry-check", execute_at: 4.hours.from_now)
    _other = create_schedule("whisper-notify", execute_at: 2.hours.from_now)

    vars = run(<<~'JIL')
      results = Schedule.search("whisper-hungry-check", 25, "ASC")::Array
      count = results.length()::Numeric
    JIL

    expect(vars[:count][:value]).to eq(2)
    expect(vars[:results][:value].map { |r| r[:id] }).to contain_exactly(s_now.id, s_later.id)
  end

  it "returns ascending or descending by execute_at" do
    s_early = create_schedule("whisper-hungry-check", execute_at: 1.hour.from_now)
    s_late = create_schedule("whisper-hungry-check", execute_at: 5.hours.from_now)

    asc = run(<<~'JIL')
      results = Schedule.search("whisper-hungry-check", 25, "ASC")::Array
    JIL
    desc = run(<<~'JIL')
      results = Schedule.search("whisper-hungry-check", 25, "DESC")::Array
    JIL

    expect(asc[:results][:value].map { |r| r[:id] }).to eq([s_early.id, s_late.id])
    expect(desc[:results][:value].map { |r| r[:id] }).to eq([s_late.id, s_early.id])
  end

  it "clamps the limit and respects it" do
    3.times { |i| create_schedule("whisper-hungry-check", execute_at: (i + 1).hours.from_now) }

    vars = run(<<~'JIL')
      results = Schedule.search("whisper-hungry-check", 2, "ASC")::Array
      count = results.length()::Numeric
    JIL

    expect(vars[:count][:value]).to eq(2)
  end

  it "returns an empty array when no schedules match" do
    vars = run(<<~'JIL')
      results = Schedule.search("nonexistent-trigger", 25, "ASC")::Array
      count = results.length()::Numeric
    JIL

    expect(vars[:count][:value]).to eq(0)
  end
end
