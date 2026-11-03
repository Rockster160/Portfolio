require "rails_helper"

# Two dials with cross-targeting chains (Phase + Swarm):
#
#   1. Phase reaches Swarm step       → Phase disables, Swarm enables.
#   2. Swarm completes a revolution   → Swarm disables, Phase enables + advances.
#
# Each transition is checked in the DB, in the action response, and in the
# MonitorChannel broadcasts, all of which must carry the post-chain state.
RSpec.describe "Slime Colony chain transitions" do
  let(:user) { create(:user) }

  let(:phase) do
    create(:timer, user: user, name: "Phase", kind: :dial,
      dial_config: { sections: [
        { name: "Emerge" }, { name: "Mush" }, { name: "Swarm" }, { name: "Settle" },
      ] },
      dial_step_index: 0,
      disabled:        false,
    )
  end

  let(:swarm) do
    create(:timer, user: user, name: "Swarm", kind: :dial,
      dial_config: { sections: [
        { name: "Foo" }, { name: "Bar" }, { name: "Baz" },
      ] },
      dial_step_index: 0,
      disabled:        true,
    )
  end

  before do
    phase.update!(callbacks: [
      { id: "phase-disable-swarm", when: { type: "dial_step", section: "Swarm" }, then: { type: "chain", target_timer_name: "Phase", op: "disable" } },
      { id: "phase-enable-swarm",  when: { type: "dial_step", section: "Swarm" }, then: { type: "chain", target_timer_id: swarm.id, op: "enable" } },
    ])

    swarm.update!(callbacks: [
      { id: "swarm-disable",   when: { type: "complete" }, then: { type: "chain", target_timer_name: "Swarm", op: "disable" } },
      { id: "phase-enable",    when: { type: "complete" }, then: { type: "chain", target_timer_id: phase.id,  op: "enable" } },
      { id: "phase-increment", when: { type: "complete" }, then: { type: "chain", target_timer_id: phase.id,  op: "increment", by: 1 } },
    ])

    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def advance!(timer)
    post timer_routes_advance_item_path(timer), params: { tab_id: "A" }, as: :json
  end

  def capture_broadcasts
    payloads = []
    allow(MonitorChannel).to receive(:broadcast_to) { |_user, env| payloads << env }
    yield
    payloads.filter_map { |env| env.dig(:data, :timer) }
  end

  def last_disabled(timers, timer)
    timers.select { |t| t[:id] == timer.id }.last&.dig(:disabled)
  end

  it "advancing Phase onto Swarm step disables Phase AND enables Swarm", :aggregate_failures do
    advance!(phase)
    expect(phase.reload.dial_step_index).to eq(1)

    timers = capture_broadcasts { advance!(phase) }
    expect(response).to have_http_status(:ok)

    expect(phase.reload.dial_step_index).to eq(2)
    expect(phase.disabled).to eq(true)
    expect(swarm.reload.disabled).to eq(false)
    expect(response.parsed_body.dig("timer", "disabled")).to eq(true)
    expect(last_disabled(timers, phase)).to eq(true)
    expect(last_disabled(timers, swarm)).to eq(false)
  end

  it "Swarm completing a revolution disables Swarm AND enables Phase", :aggregate_failures do
    # Park Phase on Swarm step so its enable chain has already fired.
    phase.update!(dial_step_index: 2, disabled: true)
    swarm.update!(dial_step_index: 0, disabled: false)

    2.times { advance!(swarm) }
    expect(swarm.reload.dial_step_index).to eq(2)

    timers = capture_broadcasts { advance!(swarm) }
    expect(response).to have_http_status(:ok)

    expect(swarm.reload.dial_step_index).to eq(0)
    expect(swarm.disabled).to eq(true)
    expect(phase.reload.disabled).to eq(false)
    expect(phase.dial_step_index).to eq(3)
    expect(response.parsed_body.dig("timer", "disabled")).to eq(true)
    expect(last_disabled(timers, swarm)).to eq(true)
    expect(last_disabled(timers, phase)).to eq(false)
  end
end
