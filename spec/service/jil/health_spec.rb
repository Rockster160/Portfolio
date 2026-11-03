require "rails_helper"

RSpec.describe Jil::Health do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:now) { Time.zone.parse("2026-06-10 12:00") }
  let(:health) { described_class.new(user, now: now) }

  around { |example| travel_to(now) { example.run } }

  def make_task(owner: user, ran_at: nil, **attrs)
    create(:task, user: owner, last_trigger_at: ran_at, **attrs)
  end

  def run!(task, at:, status: :success, error: nil)
    payload = ExecutionPayload.create!(code: task.code, ctx: { error: error }) if error
    create(:execution, task: task, status: status, started_at: at, payload: payload)
  end

  def runs!(task, count:, every:, ending:, status: :success)
    count.times { |i| run!(task, at: ending - (i * every), status: status) }
  end

  def tasks_in(bucket)
    health.public_send(bucket).map(&:task)
  end

  describe "#failing" do
    it "lists a task with a recent failed run, pointing at that run" do
      broken = make_task
      run!(broken, at: now - 3.hours, status: :failed, error: "[2] [NoMethodError] nope")
      latest = run!(broken, at: now - 1.hour, status: :failed, error: "[4] [KeyError] key")
      healthy = make_task
      run!(healthy, at: now - 1.hour)

      expect(tasks_in(:failing)).to eq([broken])
      expect(health.failing.first).to have_attributes(failed_count: 2, execution_id: latest.id, recovered: false)
    end
  end

  describe "#silent" do
    it "flags a daily cron that has not run for three days, not one that ran today" do
      stalled = make_task(listener: nil, cron: "0 9 * * *", ran_at: now - 3.days)
      make_task(listener: nil, cron: "0 9 * * *", ran_at: now - 3.hours)

      expect(tasks_in(:silent)).to eq([stalled])
      expect(health.silent.first).to have_attributes(reason: :cron, expected_every: 1.day.to_i)
    end

    it "flags a listener task quiet far past its own usual gap" do
      stopped = make_task(listener: "event:add", ran_at: now - 3.days)
      runs!(stopped, count: 10, every: 1.hour, ending: now - 3.days)
      steady = make_task(listener: "event:add", ran_at: now - 1.hour)
      runs!(steady, count: 10, every: 1.hour, ending: now - 1.hour)

      expect(tasks_in(:silent)).to eq([stopped])
    end

    it "flags a listener task that has never run once it has had time to" do
      old = make_task(listener: "tell:hello", created_at: now - 10.days)
      make_task(listener: "tell:fresh", created_at: now - 1.day)

      expect(tasks_in(:silent)).to eq([old])
    end

    it "never counts a disabled or archived task, nor a function" do
      make_task(listener: nil, cron: "0 9 * * *", ran_at: now - 5.days, enabled: false)
      make_task(listener: nil, cron: "0 9 * * *", ran_at: now - 5.days, archived_at: now - 1.day)
      make_task(listener: "function(name:String)", created_at: now - 30.days)

      expect(health.silent).to be_empty
    end
  end

  describe "#noisy" do
    it "flags a task running far above its trailing daily rate" do
      hot = make_task
      runs!(hot, count: 14, every: 1.day, ending: now - 2.days)
      runs!(hot, count: 30, every: 30.minutes, ending: now - 5.minutes)
      steady = make_task
      runs!(steady, count: 28, every: 12.hours, ending: now - 5.minutes)

      expect(tasks_in(:noisy)).to eq([hot])
    end
  end

  describe "#orphans" do
    it "lists trigger scopes no enabled task or watch listens to" do
      make_task(listener: "garage:open")
      make_task(listener: "doorbell", enabled: false)
      create(:jil_trigger_shape, user: user, scope: "garage")
      create(:jil_trigger_shape, user: user, scope: "doorbell")
      create(:jil_trigger_shape, user: user, scope: "stale", last_seen_at: now - 30.days)

      expect(health.orphans.map(&:scope)).to eq(["doorbell"])
    end
  end

  describe "scoping" do
    it "keeps to the tasks and triggers this person can see, including ones shared with them" do
      theirs = make_task(owner: other_user)
      run!(theirs, at: now - 1.hour, status: :failed)
      create(:jil_trigger_shape, user: other_user, scope: "theirs")
      shared = make_task(owner: other_user)
      SharedTask.create!(task: shared, user: user)
      run!(shared, at: now - 1.hour, status: :failed)

      expect(tasks_in(:failing)).to eq([shared])
      expect(health.orphans).to be_empty
      expect(described_class.new(user, view_scope: :all, now: now).failing.map(&:task)).to contain_exactly(theirs, shared)
    end
  end
end
