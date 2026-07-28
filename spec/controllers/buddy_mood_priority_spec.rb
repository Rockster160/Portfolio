require "rails_helper"

# Regression: a mood Buddy chose must survive even when the same reply also
# proposes/runs a tool. The old code let the proposal-state expression
# (:proposals_executed → happy, :proposals_awaiting → neutral) clobber the
# mood — and since nearly every "doing something" reply carries a proposal,
# moods almost never showed.
RSpec.describe WebhooksController, type: :controller do
  let(:user)   { User.me }
  let(:secret) { "test-secret" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("BYTE_LOCAL_SECRET", "").and_return(secret)
    request.env["HTTP_X_BYTE_SECRET"] = secret

    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    user.update_column(:buddy_theme, "byte")
    user.update_column(:buddy_expression, "thinking")
    # Isolate the expression decision from real tool execution: pretend an
    # auto-tool ran, which under the old logic forced :happy.
    allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)
  end

  let!(:convo) do
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  end
  let!(:message) do
    convo.byte_messages.create!(
      user: user, direction: :inbound, state: :streaming, body: "…", metadata: { source: "ai", kind: "buddy" },
    )
  end

  it "keeps Buddy's chosen mood even when the reply also runs a tool" do
    patch :byte_update, params: {
      id:    message.id,
      state: "delivered",
      body:  'On it. [[mood: sad]] [[propose: log_event name="Coffee"]]',
    }

    # Mood wins over the proposal-driven :happy the old code would have forced.
    expect(user.reload.buddy_expression).to eq("sad")
  end

  it "falls back to the proposal expression when there's no mood" do
    patch :byte_update, params: {
      id:    message.id,
      state: "delivered",
      body:  'Logged it. [[propose: log_event name="Coffee"]]',
    }

    # No mood → auto-tool ran → :proposals_executed → happy.
    expect(user.reload.buddy_expression).to eq("happy")
  end
end
