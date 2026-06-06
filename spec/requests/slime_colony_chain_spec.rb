require "rails_helper"

# Reproduces the exact callback layout the user dumped from prod-dev for
# the Slime Colony game (Phase + Swarm dials with cross-targeting chains)
# and walks through both transitions the user said are broken:
#
#   1. Phase reaches Swarm step       → Phase should disable, Swarm enable.
#   2. Swarm completes a revolution   → Swarm disable, Phase enable + advance.
#
# Asserts on:
#   - DB state after each tap (was the chain mutation persisted?)
#   - The action response body (does it carry FRESH state post-chain?)
#   - The MonitorChannel broadcast payloads (do they carry FRESH state?)
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
    # Phase callbacks — same shape the user dumped.
    phase.update!(callbacks: [
      { id: "phase-disable-swarm", when: { type: "dial_step", section: "Swarm" }, then: { type: "chain", target_timer_name: "Phase", op: "disable" } },
      { id: "phase-enable-swarm",  when: { type: "dial_step", section: "Swarm" }, then: { type: "chain", target_timer_id: swarm.id, op: "enable" } },
    ])

    # Swarm callbacks.
    swarm.update!(callbacks: [
      { id: "swarm-disable",   when: { type: "complete" }, then: { type: "chain", target_timer_name: "Swarm", op: "disable" } },
      { id: "phase-enable",    when: { type: "complete" }, then: { type: "chain", target_timer_id: phase.id,  op: "enable" } },
      { id: "phase-increment", when: { type: "complete" }, then: { type: "chain", target_timer_id: phase.id,  op: "increment", by: 1 } },
    ])

    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  it "advancing Phase onto Swarm step disables Phase AND enables Swarm" do
    # Phase starts at Emerge (index 0). Advance twice → Mush (1), Swarm (2).
    post timer_routes_advance_item_path(phase), params: { tab_id: "A" }, as: :json
    expect(phase.reload.dial_step_index).to eq(1)

    broadcast_payloads = []
    allow(MonitorChannel).to receive(:broadcast_to) { |_user, env| broadcast_payloads << env }

    post timer_routes_advance_item_path(phase), params: { tab_id: "A" }, as: :json
    expect(response).to have_http_status(:ok)

    phase.reload
    swarm.reload

    aggregate_failures "post-chain DB state" do
      expect(phase.dial_step_index).to eq(2)
      expect(phase.disabled).to eq(true),  "Phase should be disabled after landing on Swarm"
      expect(swarm.disabled).to eq(false), "Swarm should be enabled after Phase landed on Swarm"
    end

    body = JSON.parse(response.body)
    expect(body.dig("timer", "disabled")).to eq(true), "controller response must carry FRESH Phase disabled state"

    # At least one broadcast for Phase should carry disabled:true and at
    # least one broadcast for Swarm should carry disabled:false.
    phase_states = broadcast_payloads
      .map { |env| env.dig(:data, :timer) }
      .compact
      .select { |t| t[:id] == phase.id }
      .map { |t| t[:disabled] }
    swarm_states = broadcast_payloads
      .map { |env| env.dig(:data, :timer) }
      .compact
      .select { |t| t[:id] == swarm.id }
      .map { |t| t[:disabled] }

    expect(phase_states.last).to eq(true), "Phase's last broadcast in this request should be disabled:true"
    expect(swarm_states.last).to eq(false), "Swarm's last broadcast should be disabled:false"
  end

  it "Swarm completing a revolution disables Swarm AND enables Phase" do
    # Park Phase on Swarm step so its `phase-enable-swarm` chain has
    # ALREADY fired (Swarm is enabled) and we can test the return path.
    phase.update!(dial_step_index: 2, disabled: true)
    swarm.update!(dial_step_index: 0, disabled: false)

    # Drive Swarm through its 3 steps so the 3rd advance wraps.
    2.times do
      post timer_routes_advance_item_path(swarm), params: { tab_id: "A" }, as: :json
    end
    expect(swarm.reload.dial_step_index).to eq(2)

    broadcast_payloads = []
    allow(MonitorChannel).to receive(:broadcast_to) { |_user, env| broadcast_payloads << env }

    post timer_routes_advance_item_path(swarm), params: { tab_id: "A" }, as: :json
    expect(response).to have_http_status(:ok)

    phase.reload
    swarm.reload

    aggregate_failures "post-chain DB state" do
      expect(swarm.dial_step_index).to eq(0)
      expect(swarm.disabled).to eq(true),  "Swarm should be disabled after wrapping"
      expect(phase.disabled).to eq(false), "Phase should be enabled after Swarm wrapped"
      expect(phase.dial_step_index).to eq(3), "Phase should have advanced from Swarm (2) to Settle (3)"
    end

    body = JSON.parse(response.body)
    expect(body.dig("timer", "disabled")).to eq(true), "controller response must carry FRESH Swarm disabled state"

    phase_states = broadcast_payloads
      .map { |env| env.dig(:data, :timer) }
      .compact
      .select { |t| t[:id] == phase.id }
      .map { |t| t[:disabled] }
    swarm_states = broadcast_payloads
      .map { |env| env.dig(:data, :timer) }
      .compact
      .select { |t| t[:id] == swarm.id }
      .map { |t| t[:disabled] }

    expect(swarm_states.last).to eq(true),  "Swarm's last broadcast should be disabled:true"
    expect(phase_states.last).to eq(false), "Phase's last broadcast should be disabled:false"
  end
end
