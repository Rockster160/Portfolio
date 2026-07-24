require "rails_helper"

RSpec.describe Buddy::ProposalBuilder do
  let(:user) { FactoryBot.create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "T") }
  let(:msg)   { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hello") }

  before do
    # Register a tiny synthetic tool for shape testing so we don't depend
    # on the real 12 tool files (their resolvers hit Chore/Agenda models).
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
    action = described_class.create(user: user, byte_message: msg, markers: markers)

    expect(action).to be_a(ByteAction)
    expect(action.multi_select).to be(true)
    expect(action.tool_name).to eq("buddy_proposals")
    expect(action.buttons.length).to eq(2)
    expect(action.buttons.map { |b| b["label"] }).to eq(%w[one two])

    msg.reload
    expect(msg.metadata["kind"]).to eq("buddy_reply")
    expect(msg.metadata["action_request_id"]).to eq(action.request_id)
  end

  it "merges identical proposals via merge_key with total count" do
    markers = Array.new(3) { { tool_name: :spec_noop, payload: { thing: "same" }, span: [0, 0] } }
    action = described_class.create(user: user, byte_message: msg, markers: markers)

    expect(action.buttons.length).to eq(1)
    expect(action.buttons.first["count"]).to eq(3)
    expect(action.buttons.first["label"]).to eq("3× same")
  end

  it "discards markers whose tool is unknown" do
    markers = [
      { tool_name: :spec_noop,   payload: { thing: "ok" },   span: [0, 0] },
      { tool_name: :not_a_thing, payload: { thing: "nope" }, span: [0, 0] },
    ]
    action = described_class.create(user: user, byte_message: msg, markers: markers)

    expect(action.buttons.length).to eq(1)
    expect(action.buttons.first["label"]).to eq("ok")
  end

  it "returns nil when no markers survive validation" do
    markers = [{ tool_name: :not_a_thing, payload: {}, span: [0, 0] }]
    expect(described_class.create(user: user, byte_message: msg, markers: markers)).to be_nil
  end
end
