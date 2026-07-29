require "rails_helper"

# A Buddy reply that comes back as ONLY a marker which then gets discarded
# (couldn't resolve what to act on) must never leave a blank bubble — the person
# gets an honest fallback instead of a mystery empty message.
RSpec.describe WebhooksController, type: :controller do
  let(:user)   { User.me }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let!(:message) {
    convo.byte_messages.create!(user: user, direction: :inbound, state: :streaming, body: "…", metadata: { "kind" => "buddy" })
  }
  let(:secret) { "test-secret" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("BYTE_LOCAL_SECRET", "").and_return(secret)
    request.env["HTTP_X_BYTE_SECRET"] = secret
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_column(:buddy_theme, "byte")
  end

  it "fills a fallback body when the only marker is discarded (no blank bubble)" do
    patch :byte_update, params: {
      id:    message.id,
      state: "delivered",
      body:  '[[propose: nonexistent_tool foo="bar"]]', # unknown tool → discarded, no prose
    }

    expect(message.reload.body).to match(/couldn't quite line that one up/i)
  end

  it "leaves a normal prose reply untouched" do
    patch :byte_update, params: { id: message.id, state: "delivered", body: "Yeah, of course - here you go." }
    expect(message.reload.body).to eq("Yeah, of course - here you go.")
  end
end
