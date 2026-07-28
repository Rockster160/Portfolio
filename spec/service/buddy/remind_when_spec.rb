require "rails_helper"

# remind_when is an AUTO tool (like schedule_reminder): it runs on the spot,
# creates a BuddyWatch, and drops an activity-receipt chip - no checklist.
RSpec.describe "remind_when tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def run(payload)
    markers = [{ tool_name: :remind_when, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  it "creates a chore-condition watch as an auto tool (no checklist)" do
    result = nil
    expect { result = run(text: "floss", trigger: "chore", target: "Brush Teeth") }
      .to change { BuddyWatch.count }.by(1)

    expect(result[:action]).to be_nil
    expect(result[:auto_ran]).to be(true)

    w = BuddyWatch.last
    expect(w.trigger_scope).to eq("chore_completion")
    expect(w.match).to eq("action" => "completed", "chore_name" => "Brush Teeth")
    expect(w.kind).to eq("prompt")
    expect(w.one_shot).to be(true)

    chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    expect(chip.body).to match(/will remind you next time you finish Brush Teeth/)
  end

  it "builds a location watch (arrive), falling back to the raw place name" do
    run(text: "grab my RX", trigger: "arrive", target: "costco")
    w = BuddyWatch.last
    expect(w.trigger_scope).to eq("travel")
    expect(w.match["action"]).to eq("arrived")
    expect(w.match["location"]).to eq("costco")
  end

  it "builds a deploy watch with an empty match" do
    run(text: "the deploy's done", trigger: "deploy")
    w = BuddyWatch.last
    expect(w.trigger_scope).to eq("deploy")
    expect(w.match).to eq({})
  end

  it "makes a repeating watch when repeat=true" do
    run(text: "floss", trigger: "chore", target: "Brush Teeth", repeat: true)
    expect(BuddyWatch.last.one_shot).to be(false)
  end

  it "surfaces active watches in Buddy::Context" do
    run(text: "floss", trigger: "chore", target: "Brush Teeth")
    ctx = Buddy::Context.build(user)
    expect(ctx[:active_watches].map { |w| w[:body] }).to include("floss")
    expect(ctx[:active_watches].first[:when]).to include("Brush Teeth")
  end
end
