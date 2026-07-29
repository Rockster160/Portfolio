require "rails_helper"

# Regression: a mood Buddy chose must survive even when the same reply also
# proposes/runs a tool, AND a reply with no mood must leave the persistent mood
# exactly where it was (no auto-revert to a default). The old code let the
# proposal-state expression clobber the mood; the new model keeps the mood put
# until a [[mood:]] / check-in / sleep deliberately moves it.
RSpec.describe WebhooksController, type: :controller do
  let(:user)   { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }
  let!(:message) {
    convo.byte_messages.create!(
      user: user, direction: :inbound, state: :streaming, body: "…", metadata: { source: "ai", kind: "buddy" },
    )
  }
  let(:secret) { "test-secret" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("BYTE_LOCAL_SECRET", "").and_return(secret)
    request.env["HTTP_X_BYTE_SECRET"] = secret

    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_column(:buddy_theme, "byte")
    # A real mood the pet is already wearing before this turn.
    convo.update_column(:buddy_expression, "happy")
    # Isolate the expression decision from real tool execution.
    allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)
  end

  it "applies Buddy's chosen mood even when the reply also runs a tool" do
    patch :byte_update, params: {
      id:    message.id,
      state: "delivered",
      body:  'On it. [[mood: sad]] [[propose: log_event name="Coffee"]]',
    }

    expect(convo.reload.buddy_expression).to eq("sad")
  end

  it "leaves the mood untouched when the reply carries no mood marker" do
    patch :byte_update, params: {
      id:    message.id,
      state: "delivered",
      body:  'Logged it. [[propose: log_event name="Coffee"]]',
    }

    # No mood marker → the persistent mood stays exactly as it was (happy).
    # Nothing reverts it to a default just because the turn ended.
    expect(convo.reload.buddy_expression).to eq("happy")
  end
end
