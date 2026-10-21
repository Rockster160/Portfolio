require "rails_helper"

# A prompt form asking to be rebuilt as it's shown. The answer goes out as an
# ordinary message update; the response only says it happened.
RSpec.describe "Refreshing a form in the thread", type: :request do
  let(:user) { User.me }
  let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }
  let(:prompt) {
    user.prompts.create!(question: "Shopping at Costco", options: [{ type: :text, question: "Spent", default: "" }])
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def refresh!(action)
    post byte_action_refresh_path(request_id: action.request_id)
  end

  it "rebuilds a pending prompt form" do
    action = Buddy::PromptDelivery.post!(user, prompt)
    prompt.update!(question: "Shopping at Harmon's")

    refresh!(action)

    expect(response).to have_http_status(:ok)
    expect(action.byte_message.reload.body).to eq("Shopping at Harmon's")
  end

  it "refuses once the prompt has been answered" do
    action = Buddy::PromptDelivery.post!(user, prompt)
    prompt.update!(response: { "Spent" => "12" })

    refresh!(action)

    expect(response).to have_http_status(:conflict)
  end

  it "is only for forms" do
    card = ByteAction.create_request!(
      user: user, conversation: conversation, kind: :question, tool_name: "buddy_pick",
      buttons: [{ "id" => 1, "label" => "x", "value" => "x" }], timeout_seconds: 1.hour,
    )

    refresh!(card)

    expect(response).to have_http_status(:not_found)
  end
end
