require "rails_helper"

RSpec.describe WebhooksController, type: :controller do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(name: "target", mode: :claude, metadata: { cwd: "/old/path" }) }
  let(:secret) { "test-secret-32chars-long" }

  before do
    stub_const("ByteLocal::TIMEOUT_SECONDS", 1)
    allow(ByteLocal).to receive(:secret).and_return(secret)
    request.headers["X-Byte-Secret"] = secret
    request.headers["Content-Type"]  = "application/json"
  end

  describe "PATCH #byte_update_conversation" do
    it "merges metadata rather than replacing it" do
      patch :byte_update_conversation, params: {
        id:       convo.id,
        metadata: { cwd: "/new/path" }.to_json,
      }

      expect(response).to be_successful
      convo.reload
      expect(convo.metadata["cwd"]).to eq("/new/path")
    end

    it "leaves untouched metadata keys alone" do
      convo.update!(metadata: { cwd: "/old", claude_session_id: "abc" })

      patch :byte_update_conversation, params: {
        id:       convo.id,
        metadata: { cwd: "/new" }.to_json,
      }

      convo.reload
      expect(convo.metadata["cwd"]).to eq("/new")
      expect(convo.metadata["claude_session_id"]).to eq("abc")
    end

    it "rejects requests without a valid secret" do
      request.headers["X-Byte-Secret"] = "wrong"
      patch :byte_update_conversation, params: { id: convo.id, metadata: {} }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an unknown conversation" do
      patch :byte_update_conversation, params: { id: -1, metadata: { cwd: "/x" }.to_json }
      expect(response).to have_http_status(:not_found)
    end
  end
end
