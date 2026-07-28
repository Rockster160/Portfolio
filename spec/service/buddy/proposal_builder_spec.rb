require "rails_helper"

RSpec.describe Buddy::ProposalBuilder do
  let(:user) { FactoryBot.create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "T") }
  let(:msg)   { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hello") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    # A tiny synthetic CONFIRM tool for shape testing so we don't depend on
    # the real tool files (their resolvers hit Chore/Agenda models).
    Buddy::Tools.register(
      name:        :spec_noop,
      description: "no-op used in specs",
      args:        { thing: { type: :string, required: true } },
      confirm:     ->(p, _) { { summary: "Do #{p[:thing]}?", resolved: {} } },
      label:       ->(p, _) { p[:thing].to_s },
      merge_key:   ->(p) { "spec_noop:#{p[:thing]}" },
      merge_label: ->(p, n) { "#{n}× #{p[:thing]}" },
      execute:     ->(p, _) { { echoed: p[:thing] } },
      receipt:     ->(r, _) { "Did #{r[:echoed]}" },
    )
  end

  it "creates a ByteAction with per-marker button rows" do
    markers = [
      { tool_name: :spec_noop, payload: { thing: "one" }, span: [0, 0] },
      { tool_name: :spec_noop, payload: { thing: "two" }, span: [0, 0] },
    ]
    result = described_class.create(user: user, byte_message: msg, markers: markers)
    action = result[:action]

    expect(action).to be_a(ByteAction)
    expect(action.multi_select).to be(true)
    expect(action.tool_name).to eq("buddy_proposals")
    expect(action.buttons.length).to eq(2)
    expect(action.buttons.map { |b| b["label"] }).to eq(%w[one two])
    expect(result[:auto_ran]).to be(false)

    msg.reload
    expect(msg.metadata["kind"]).to eq("buddy_reply")
    expect(msg.metadata["action_request_id"]).to eq(action.request_id)
  end

  it "merges identical proposals via merge_key with total count" do
    markers = Array.new(3) { { tool_name: :spec_noop, payload: { thing: "same" }, span: [0, 0] } }
    action = described_class.create(user: user, byte_message: msg, markers: markers)[:action]

    expect(action.buttons.length).to eq(1)
    expect(action.buttons.first["count"]).to eq(3)
    expect(action.buttons.first["label"]).to eq("3× same")
  end

  it "discards markers whose tool is unknown" do
    markers = [
      { tool_name: :spec_noop,   payload: { thing: "ok" },   span: [0, 0] },
      { tool_name: :not_a_thing, payload: { thing: "nope" }, span: [0, 0] },
    ]
    action = described_class.create(user: user, byte_message: msg, markers: markers)[:action]

    expect(action.buttons.length).to eq(1)
    expect(action.buttons.first["label"]).to eq("ok")
  end

  it "returns no action when no markers survive validation" do
    markers = [{ tool_name: :not_a_thing, payload: {}, span: [0, 0] }]
    result = described_class.create(user: user, byte_message: msg, markers: markers)
    expect(result[:action]).to be_nil
    expect(result[:auto_ran]).to be(false)
  end

  context "auto (no-confirm) tools" do
    before do
      Buddy::Tools.register(
        name:        :spec_auto,
        description: "auto tool used in specs",
        args:        { thing: { type: :string, required: true } },
        confirm:     ->(p, _) { { summary: "x", resolved: {} } },
        label:       ->(p, _) { p[:thing].to_s },
        execute:     ->(p, _) { { echoed: p[:thing] } },
        receipt:     ->(r, _) { "Handled #{r[:echoed]}" },
        auto:        true,
      )
    end

    it "runs immediately, posts an activity chip, and creates NO checklist" do
      markers = [{ tool_name: :spec_auto, payload: { thing: "reminder" }, span: [0, 0] }]

      expect {
        result = described_class.create(user: user, byte_message: msg, markers: markers)
        expect(result[:action]).to be_nil
        expect(result[:auto_ran]).to be(true)
      }.to change { convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").count }.by(1)

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to eq("Handled reminder")
      expect(chip.direction).to eq("inbound")
    end

    it "mixes: auto runs, confirm tool still becomes a checklist" do
      markers = [
        { tool_name: :spec_auto, payload: { thing: "r" }, span: [0, 0] },
        { tool_name: :spec_noop, payload: { thing: "c" }, span: [0, 0] },
      ]
      result = described_class.create(user: user, byte_message: msg, markers: markers)

      expect(result[:auto_ran]).to be(true)
      expect(result[:action].buttons.map { |b| b["label"] }).to eq(["c"])
    end
  end
end
