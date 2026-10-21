require "rails_helper"

# Pressing a button under a Buddy message: it fires the button's trigger once,
# and only for a button the message really offered.
RSpec.describe "Buddy message buttons", type: :request do
  let(:user) { User.me }
  let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }
  let(:action) { ByteAction.find_by(user: user, tool_name: Buddy::MessageButtons::TOOL_NAME) }

  before do
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(Jil).to receive(:trigger).and_call_original
    user.update!(password: "password123", password_confirmation: "password123")
    Buddy::MessageButtons.send!(
      owner: user, users: [user], key: "door-open", text: "The door is open!",
      buttons: [{ label: "Close the door", trigger: "door", data: { "direction" => "close" } }]
    )
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def press!(value)
    post byte_action_respond_path(request_id: action.request_id), params: { value: value }
  end

  it "fires the trigger and settles the message" do
    press!(1)

    expect(response).to have_http_status(:ok)
    expect(Jil).to have_received(:trigger).with(user, "door", hash_including("direction" => "close"), auth: :trigger)
    expect(action.reload).to be_decided
    expect(action.byte_message.reload.metadata["buttons_outcome"]).to eq("You pressed \"Close the door\"")
  end

  it "refuses a button the message never offered" do
    press!(7)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(action.reload).to be_pending
    expect(Jil).not_to have_received(:trigger).with(user, "door", anything, anything)
  end

  it "does nothing on a second press" do
    press!(1)
    press!(1)

    expect(response).to have_http_status(:conflict)
    expect(Jil).to have_received(:trigger).with(user, "door", anything, auth: :trigger).once
  end
end
