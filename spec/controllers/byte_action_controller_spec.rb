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

    context "with a buddy_proposals action (incremental checkbox taps)" do
      let(:buddy_convo) { user.byte_conversations.create!(name: "b", mode: :buddy) }

      def proposal_action
        ByteAction.create_request!(
          user: user, conversation: buddy_convo, kind: :custom,
          tool_name: "buddy_proposals", multi_select: true,
          buttons: [
            { "id" => 1, "label" => "A", "tool_name" => "spec_x", "payload" => {}, "status" => "pending" },
            { "id" => 2, "label" => "B", "tool_name" => "spec_x", "payload" => {}, "status" => "pending" },
          ],
        )
      end

      it "enqueues the executor with the tapped ids and leaves the action pending" do
        action = proposal_action

        expect(Buddy::ProposalExecutorJob).to receive(:perform_later).with(action.id, [1])

        post :respond_action, params: { request_id: action.request_id, value: [1] }

        expect(response).to be_successful
        # Incremental — the action is NOT decided by the tap itself; the
        # executor decides it only once every row is resolved.
        expect(action.reload).to be_pending
      end

      it "does not notify the Mac decision hook (no blocked hook waits on these)" do
        action = proposal_action
        allow(Buddy::ProposalExecutorJob).to receive(:perform_later)

        expect(ByteLocal).not_to receive(:notify_action_decision)

        post :respond_action, params: { request_id: action.request_id, value: [1] }
        expect(response).to be_successful
      end
    end

    # An editable form posts VALUES, not row ids, so it can't lean on the
    # id-lookup safety the other shapes get incidentally — validation is the
    # whole job of this branch.
    context "with a buddy_form action" do
      let(:buddy_convo) { user.byte_conversations.create!(name: "b", mode: :buddy) }
      let(:prompt) {
        Prompt.create!(user: user, answer_type: :single, question: "How many calories?", options: [
          { "type" => "text", "default" => "shake", "question" => "Notes" },
          { "type" => "text", "default" => "",      "question" => "Calories" },
        ])
      }

      before {
        allow(MonitorChannel).to receive(:broadcast_to)
        allow(::Jil).to receive(:trigger).and_return(true)
        allow(::WebPushNotifications).to receive(:update_count)
      }

      def form_action(answers = {})
        Buddy::FormAction.post!(
          user: user, conversation: buddy_convo,
          tool: Buddy::Tools[:answer_prompt], payload: { id: prompt.id, answers: answers },
        )
      end

      it "submits the values the person sent" do
        action = form_action("Calories" => "240")

        post :respond_action, params: {
          request_id: action.request_id, form: { "Notes" => "shake", "Calories" => "180" },
        }

        expect(response).to be_successful
        expect(prompt.reload.response).to eq("Notes" => "shake", "Calories" => "180")
      end

      it "answers a half-filled form with 422 and the reasons, keeping it live" do
        action = form_action

        post :respond_action, params: {
          request_id: action.request_id, form: { "Notes" => "shake", "Calories" => "" },
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["errors"].join).to include("Calories needs a value")
        expect(action.reload).to be_pending
      end

      it "can't be submitted by someone else" do
        action = form_action("Calories" => "240")
        sign_in create(:user)

        post :respond_action, params: { request_id: action.request_id, form: { "Calories" => "1" } }

        expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
        expect(prompt.reload.response).to be_nil
      end
    end
  end
end
