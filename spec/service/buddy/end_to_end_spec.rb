require "rails_helper"

# Integration-style smoke: mimic the full Buddy pipeline from a Mac
# reply landing at /webhooks/byte through the user tapping a checkbox
# and Buddy::ProposalExecutor doing the tool-side work. No HTTP —
# calls the service seams directly to keep the test tight and fast.
RSpec.describe "Buddy end-to-end" do
  let(:user)  { FactoryBot.create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }

  before do
    # Reset the registry so a real tool file doesn't collide with our
    # synthetic one during the spec run.
    @side_effects = []
    side_effects  = @side_effects
    Buddy::Tools.register(
      name:        :e2e_log,
      description: "spec-only",
      args:        { name: { type: :string, required: true } },
      confirm:     ->(p, _) { { summary: "Log #{p[:name]}?", resolved: {} } },
      label:       ->(p, _) { p[:name].to_s },
      merge_key:   ->(p) { "e2e_log:#{p[:name]}" },
      merge_label: ->(p, n) { "#{n}× #{p[:name]}" },
      execute:     ->(p, _) { side_effects << p[:name]; { name: p[:name] } },
      receipt:     ->(r, _) { "Logged #{r[:name]}" },
    )
  end

  it "parses markers, creates a checkbox action, executes checked items" do
    # 1. Simulate the inbound reply Rails would persist from Mac.
    body = %(You did a lot today.\n\n[[propose: e2e_log name="Coffee"]]\n[[propose: e2e_log name="Coffee"]]\n[[propose: e2e_log name="Walk"]])
    msg = convo.byte_messages.create!(
      user:         user,
      direction:    :inbound,
      state:        :delivered,
      body:         body,
      delivered_at: Time.current,
    )

    # 2. The webhooks_controller hook: parse + strip + build proposals.
    parsed = Buddy::MarkerParser.extract(msg.body)
    msg.update!(body: parsed[:display_text])
    action = Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: parsed[:markers])[:action]

    # Two Coffee markers merged, one Walk stays independent → 2 rows.
    expect(action.buttons.length).to eq(2)
    coffee_row = action.buttons.find { |b| b["label"].include?("Coffee") }
    walk_row   = action.buttons.find { |b| b["label"].include?("Walk") }
    expect(coffee_row["count"]).to eq(2)
    expect(walk_row["count"]).to eq(1)

    # 3. User taps only the Coffee row → apply_decision! + executor.
    action.apply_decision!(value: [coffee_row["id"]])
    Buddy::ProposalExecutor.perform(action.id)

    # Coffee executed twice (count=2), Walk was left unchecked → cancelled.
    expect(@side_effects).to eq(["Coffee", "Coffee"])
    action.reload
    expect(action.buttons.find { |b| b["id"] == coffee_row["id"] }["status"]).to eq("executed")
    expect(action.buttons.find { |b| b["id"] == walk_row["id"] }["status"]).to eq("cancelled")

    # 4. A receipt message got posted into the conversation.
    receipts = convo.byte_messages.where("metadata->>'kind' = 'buddy_receipt'")
    expect(receipts.count).to eq(1)
    expect(receipts.first.body).to include("Coffee")
  end
end
