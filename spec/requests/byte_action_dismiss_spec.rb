require "rails_helper"

# The × on an action card: put away without an answer. Nothing runs, and the
# card stops holding the bottom of the thread.
RSpec.describe "Dismissing an action card", type: :request do
  let(:user) { User.me }
  let(:conversation) { ByteConversation.create!(user: user, buddy_theme: :byte) }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def card(kind: :question, tool_name: "buddy_pick")
    ByteAction.create_request!(
      user: user, conversation: conversation, kind: kind, tool_name: tool_name,
      buttons: [{ "id" => 1, "label" => "Puppy Fed", "value" => "Puppy Fed" }], timeout_seconds: 1.hour,
    )
  end

  def dismiss!(action)
    post byte_action_dismiss_path(request_id: action.request_id)
  end

  it "settles the card without running anything" do
    action = card
    expect(Buddy::Disambiguation).not_to receive(:chose!)

    dismiss!(action)

    expect(response).to have_http_status(:ok)
    expect(action.reload).to be_aborted
    expect(action.byte_message.reload.metadata["action_state"]).to eq("dismissed")
  end

  it "can't then be answered" do
    action = card
    dismiss!(action)

    post byte_action_respond_path(request_id: action.request_id), params: { value: "Puppy Fed" }
    expect(response).to have_http_status(:conflict)
  end

  it "leaves an answered card alone" do
    action = card
    action.apply_decision!(value: "Puppy Fed")

    dismiss!(action)
    expect(response).to have_http_status(:conflict)
    expect(action.reload).to be_decided
  end

  # A Claude Code hook sits blocked on these; they have their own Deny.
  it "won't put away a permission a hook is waiting on" do
    action = card(kind: :permission, tool_name: "Bash")

    dismiss!(action)
    expect(response).to have_http_status(:conflict)
    expect(action.reload).to be_pending
  end
end
