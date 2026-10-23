require "rails_helper"

# "When the doggy door opens, quiet the house and turn the porch light on."
#
# One watch that runs two things, said the way the model says anything: a
# `remind_when` carrying `then_run_rest`, then the two calls it would make to
# do them now. Those two must not happen now - one of them acts inside the
# turn and would otherwise have already run by the time the watch existed -
# and they must come out the other side as the watch's own steps.
RSpec.describe "Holding the rest of a reply behind a watch" do
  let(:user) { create(:user) }
  let!(:sensor) {
    Task.create!(
      user: user, name: "Doggy Door Log", listener: "hass-sensor:device_name::doggy_door",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:quiet) {
    Task.create!(
      user: user, name: "Whisper Quiet", listener: "whisper-quiet", description: "Drops the volume",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:porch) {
    Task.create!(
      user: user, name: "Porch Light On", listener: "porch-light-on", description: "Turns the porch light on",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::Jil).to receive(:trigger).and_return(true)
    Rails.cache.delete("jil:wired_scopes:#{user.id}")
    convo.update_columns(buddy_theme: "byte", buddy_expression: "happy")
  end

  def watch_call(id: "w1", **extra)
    {
      name:      :remind_when,
      call_id:   id,
      arguments: {
        "text"          => "Quieting down for the night.",
        "trigger"       => "custom",
        "listener"      => "hass-sensor:device_name::doggy_door",
        "when_phrase"   => "when the doggy door opens",
        "then_run_rest" => true,
      }.merge(extra.transform_keys(&:to_s)),
    }
  end

  def task_call(name, id:)
    { name: :run_jil_task, call_id: id, arguments: { "name" => name } }
  end

  def run(calls, text: "When the doggy door opens, quiet the house and turn the porch light on")
    client = FakeBuddyClient.new([{ tool_calls: calls }, { text: "Set - I'll do both when the doggy door opens." }])
    Buddy::GPT::Turn.run!(convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text), client: client)
    client
  end

  def outputs(client)
    rows = client.calls.flat_map { |c| c.input.select { |i| i[:type] == :function_call_output } }
    rows.uniq { |i| i[:call_id] }.to_h { |i| [i[:call_id], JSON.parse(i[:output])] }
  end

  it "runs nothing now" do
    run([watch_call, task_call("Whisper Quiet", id: "t1"), task_call("Porch Light On", id: "t2")])

    expect(::Jil).not_to have_received(:trigger).with(user, anything, anything, anything)
  end

  it "makes them the watch's steps, in the order they were said" do
    run([watch_call, task_call("Whisper Quiet", id: "t1"), task_call("Porch Light On", id: "t2")])

    watch = BuddyWatch.where(user: user).last
    expect(watch.kind).to eq("action")
    expect(watch.run_steps.map { |s| s.dig("payload", "name") }).to eq(["Whisper Quiet", "Porch Light On"])
    expect(watch.body).to eq("Quieting down for the night.")
  end

  it "tells the model each one is held, not done" do
    client = run([watch_call, task_call("Whisper Quiet", id: "t1"), task_call("Porch Light On", id: "t2")])

    expect(outputs(client)["t1"]).to include("status" => "held")
    expect(outputs(client)["t2"]["note"]).to include("step 2", "never as done")
  end

  # The shape the model emits "turn the light on when I get home" in: the
  # thing to do first, the time phrase after it as a second deliverable.
  it "holds a do-it-now call that came just before the watch" do
    run([task_call("Porch Light On", id: "t1"), watch_call])

    expect(::Jil).not_to have_received(:trigger).with(user, anything, anything, anything)
    expect(BuddyWatch.where(user: user).last.run_steps.map { |s| s.dig("payload", "name") }).to eq(["Porch Light On"])
  end

  it "holds calls from a later round too" do
    client = FakeBuddyClient.new([
      { tool_calls: [watch_call] },
      { tool_calls: [task_call("Whisper Quiet", id: "t1")] },
      { text: "Done." },
    ])
    Buddy::GPT::Turn.run!(convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "when the doggy door opens, quiet the house"), client: client)

    expect(BuddyWatch.where(user: user).last.run_steps.size).to eq(1)
  end

  it "refuses a step that can't run, while they're still here" do
    client = run([watch_call, task_call("Teleporter", id: "t1")])

    expect(outputs(client)["t1"]).to include("status" => "failed")
  end

  it "refuses to hold steps behind a watch that's also messaging someone" do
    client = run([watch_call(notify: "Chelsea"), task_call("Whisper Quiet", id: "t1")])

    expect(outputs(client)["t1"]).to include("status" => "failed")
    expect(outputs(client)["t1"]["error"]).to include("`notify`")
  end

  it "lets lookups through - the model needs those now" do
    client = run([watch_call, { name: :get_context, call_id: "g1", arguments: { "sections" => ["chores_all"] } }])

    expect(outputs(client)["g1"]["status"]).not_to eq("held")
  end

  it "runs the held steps when the watch trips" do
    run([watch_call, task_call("Whisper Quiet", id: "t1"), task_call("Porch Light On", id: "t2")])
    ran = nil
    allow(Buddy::ProposalBuilder).to receive(:run_markers!) { |args| ran = args }

    Buddy::WatchMatcher.fire!(BuddyWatch.where(user: user).last)

    expect(ran[:markers].map { |m| m[:payload][:name] }).to eq(["Whisper Quiet", "Porch Light On"])
  end

  describe "behind a timed reminder" do
    def remind_call
      {
        name:      :schedule_reminder,
        call_id:   "r1",
        arguments: { "text" => "Locking up.", "at" => 3.hours.from_now.iso8601, "then_run_rest" => true },
      }
    end

    it "stores them as what the reminder runs" do
      run([remind_call, task_call("Whisper Quiet", id: "t1"), task_call("Porch Light On", id: "t2")], text: "at 9 quiet the house and turn the porch light on")

      reminder = BuddyReminder.where(user: user).last
      expect(reminder.action_calls.map { |c| c[:payload][:name] }).to eq(["Whisper Quiet", "Porch Light On"])
      expect(::Jil).not_to have_received(:trigger).with(user, anything, anything, anything)
    end
  end

  # Made one request's worth of rows, so they're one plan.
  it "puts what one reply schedules in one plan" do
    run([watch_call, task_call("Whisper Quiet", id: "t1")])

    expect(BuddyWatch.where(user: user).last.plan_id).to match(/\Ap\d+\z/)
  end
end
