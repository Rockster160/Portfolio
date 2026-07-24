require "rails_helper"

RSpec.describe ByteController, type: :controller do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(name: "t", mode: :claude) }

  before do
    allow(ByteLocal).to receive(:notify_action_decision).and_return(nil)
    sign_in user
  end

  describe "POST #respond_action" do
    it "records a single-value decision and updates the message" do
      action = ByteAction.create_request!(
        user: user, conversation: convo, kind: :permission,
        title: "Bash", buttons: [{ label: "Allow", value: "allow" }, { label: "Deny", value: "deny" }],
      )

      post :respond_action, params: { request_id: action.request_id, value: "allow" }

      expect(response).to be_successful
      body = JSON.parse(response.body)
      expect(body["state"]).to eq("decided")
      expect(body["decision"]["value"]).to eq("allow")
      expect(action.reload.decided?).to eq(true)
    end

    it "records a multi-value decision as an array" do
      action = ByteAction.create_request!(
        user: user, conversation: convo, kind: :question,
        buttons: [{ label: "A", value: "a" }, { label: "B", value: "b" }],
        multi_select: true,
      )

      post :respond_action, params: { request_id: action.request_id, value: ["a", "b"] }

      expect(response).to be_successful
      expect(action.reload.decision["value"]).to eq(["a", "b"])
    end

    it "returns 409 if the action was already decided" do
      action = ByteAction.create_request!(
        user: user, conversation: convo, kind: :permission,
        buttons: [{ label: "Ok", value: "ok" }],
      )
      action.apply_decision!(value: "ok")

      post :respond_action, params: { request_id: action.request_id, value: "ok" }

      expect(response).to have_http_status(:conflict)
    end

    it "returns 404 if the request_id is unknown" do
      post :respond_action, params: { request_id: "no-such-id", value: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "for Jarvis-kind actions, dispatches a follow-up Jarvis command" do
      jarvis_convo = user.byte_conversations.create!(name: "j", mode: :jarvis)
      action = ByteAction.create_request!(
        user: user, conversation: jarvis_convo, kind: :jarvis,
        buttons: [{ label: "Kitchen", value: "kitchen" }],
      )

      expect(ByteJarvisWorker).to receive(:perform_async).with(kind_of(Integer))

      post :respond_action, params: { request_id: action.request_id, value: "kitchen" }
      expect(response).to be_successful
      # The synthesised outbound message with body="kitchen" should be there.
      expect(jarvis_convo.byte_messages.outbound.last.body).to eq("kitchen")
    end
  end
end
