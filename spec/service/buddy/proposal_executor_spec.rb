require "rails_helper"

RSpec.describe Buddy::ProposalExecutor do
  let(:user) { FactoryBot.create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "T") }
  let(:msg)   { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi") }

  before do
    @executed = []
    executed = @executed
    Buddy::Tools.register(
      name:        :spec_track,
      description: "tracks executions",
      args:        { tag: { type: :string, required: true } },
      confirm:     ->(p, _) { { summary: "Do #{p[:tag]}?", resolved: {} } },
      label:       ->(p, _) { p[:tag].to_s },
      execute:     ->(p, _) { executed << p[:tag]; { echoed: p[:tag] } },
      receipt:     ->(r, _) { "Did #{r[:echoed]}" },
    )
  end

  it "runs checked proposals and cancels unchecked ones" do
    action = ByteAction.create!(
      user:              user,
      byte_conversation: convo,
      byte_message:      msg,
      kind:              :custom,
      tool_name:         "buddy_proposals",
      multi_select:      true,
      buttons:           [
        { "id" => 1, "label" => "A", "tool_name" => "spec_track", "payload" => { "tag" => "A" }, "count" => 1, "status" => "pending" },
        { "id" => 2, "label" => "B", "tool_name" => "spec_track", "payload" => { "tag" => "B" }, "count" => 1, "status" => "pending" },
      ],
      decision:          { "value" => [1] },
      tool_input:        {},
    )

    described_class.perform(action.id)
    action.reload

    expect(@executed).to eq(["A"])
    expect(action.buttons.find { |b| b["id"] == 1 }["status"]).to eq("executed")
    expect(action.buttons.find { |b| b["id"] == 2 }["status"]).to eq("cancelled")
  end

  it "loops the executor `count` times when count > 1" do
    action = ByteAction.create!(
      user:              user,
      byte_conversation: convo,
      byte_message:      msg,
      kind:              :custom,
      tool_name:         "buddy_proposals",
      multi_select:      true,
      buttons:           [
        { "id" => 1, "label" => "5× A", "tool_name" => "spec_track", "payload" => { "tag" => "A" }, "count" => 5, "status" => "pending" },
      ],
      decision:          { "value" => [1] },
      tool_input:        {},
    )

    described_class.perform(action.id)
    expect(@executed).to eq(["A", "A", "A", "A", "A"])
    expect(action.reload.buttons.first["status"]).to eq("executed")
  end

  # ---- incremental path (Buddy checkbox taps) ----------------------------

  def two_button_action
    ByteAction.create!(
      user:              user,
      byte_conversation: convo,
      byte_message:      msg,
      kind:              :custom,
      tool_name:         "buddy_proposals",
      multi_select:      true,
      buttons:           [
        { "id" => 1, "label" => "A", "tool_name" => "spec_track", "payload" => { "tag" => "A" }, "count" => 1, "status" => "pending" },
        { "id" => 2, "label" => "B", "tool_name" => "spec_track", "payload" => { "tag" => "B" }, "count" => 1, "status" => "pending" },
      ],
      decision:          {},
      tool_input:        {},
    )
  end

  it "runs only the requested row and leaves the rest pending (not cancelled)" do
    action = two_button_action

    described_class.perform(action.id, [1])
    action.reload

    expect(@executed).to eq(["A"])
    expect(action.buttons.find { |b| b["id"] == 1 }["status"]).to eq("executed")
    # The untouched row stays live — this is the whole point of incremental.
    expect(action.buttons.find { |b| b["id"] == 2 }["status"]).to eq("pending")
    expect(action).to be_pending
  end

  it "is idempotent across repeat/overlapping taps — never double-runs a row" do
    action = two_button_action

    described_class.perform(action.id, [1])
    described_class.perform(action.id, [1])       # repeat tap / stale job
    expect(@executed).to eq(["A"])                # ran once, not twice

    described_class.perform(action.id, [1, 2])    # full set resent; only B is new
    expect(@executed).to eq(["A", "B"])
  end

  it "decides the action once every row is resolved" do
    action = two_button_action

    described_class.perform(action.id, [1])
    expect(action.reload).to be_pending           # B still open

    described_class.perform(action.id, [2])
    action.reload
    expect(action).to be_decided                  # nothing left pending
    expect(action.buttons.map { |b| b["status"] }).to all(eq("executed"))
  end
end
