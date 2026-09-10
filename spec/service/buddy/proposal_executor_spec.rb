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

  # ---- where the receipt goes ---------------------------------------------
  #
  # THE ROW IS THE RECEIPT. It ticks, it locks, it wears a ✓, and it carries the
  # tool's own words underneath. A bubble repeating that is a second broadcast
  # about something the person is looking at — and on a checklist worked through
  # one box at a time it was one bubble per box (prod 5833-5835: three of them,
  # under three ticked rows that already said the same thing).
  #
  # Prod 1260-1261 is why the WORDS are the tool's own rather than a generic
  # "Done: Shower ✓", which read as the shower having been taken.
  describe "the receipt" do
    def receipt_bubbles
      convo.byte_messages.where("metadata->>'kind' = ?", "buddy_receipt").pluck(:body)
    end

    it "rides on the row, in the tool's own words" do
      action = two_button_action

      described_class.perform(action.id, [1])

      expect(action.reload.buttons.find { |b| b["id"] == 1 }["receipt"]).to eq("Did A")
    end

    it "posts nothing into the thread" do
      action = two_button_action

      expect { described_class.perform(action.id, [1, 2]) }.not_to change(ByteMessage, :count)
      expect(receipt_bubbles).to be_empty
    end

    it "leaves the row bare when the tool declines a receipt - the ✓ is the whole story" do
      Buddy::Tools.register(
        name:        :spec_quiet,
        description: "no receipt",
        args:        {},
        confirm:     ->(_p, _) { { summary: "Quiet?", resolved: {} } },
        label:       ->(_p, _) { "Quiet" },
        execute:     ->(_p, _) { {} },
        receipt:     ->(_r, _) {},
      )
      action = ByteAction.create!(
        user:              user,
        byte_conversation: convo,
        byte_message:      msg,
        kind:              :custom,
        tool_name:         "buddy_proposals",
        multi_select:      true,
        buttons:           [
          { "id" => 1, "label" => "Quiet", "tool_name" => "spec_quiet", "payload" => {}, "count" => 1, "status" => "pending" },
        ],
        decision:          {},
        tool_input:        {},
      )

      described_class.perform(action.id, [1])

      expect(action.reload.buttons.first["status"]).to eq("executed")
      expect(action.buttons.first["receipt"]).to be_blank
      expect(receipt_bubbles).to be_empty
    end

    # A failed row is red with the error inline on it, which is more than the
    # summary line ever carried.
    it "posts nothing for a failure either" do
      Buddy::Tools.register(
        name:        :spec_boom,
        description: "always fails",
        args:        {},
        confirm:     ->(_p, _) { { summary: "Boom?", resolved: {} } },
        label:       ->(_p, _) { "Boom" },
        execute:     ->(_p, _) { raise "nope" },
        receipt:     ->(_r, _) { "never reached" },
      )
      action = ByteAction.create!(
        user:              user,
        byte_conversation: convo,
        byte_message:      msg,
        kind:              :custom,
        tool_name:         "buddy_proposals",
        multi_select:      true,
        buttons:           [
          { "id" => 1, "label" => "Boom", "tool_name" => "spec_boom", "payload" => {}, "count" => 1, "status" => "pending" },
        ],
        decision:          {},
        tool_input:        {},
      )

      expect { described_class.perform(action.id, [1]) }.not_to change(ByteMessage, :count)
      expect(action.reload.buttons.first["status"]).to eq("failed")
      expect(action.buttons.first["error_message"]).to be_present
    end
  end
end
