require "rails_helper"

# Letting go of a condition that is still standing open.
#
# It is NOT resolving it — nobody checked. What it buys is the KEY: while an
# alert stands open it owns its key, so every later occurrence lands on the same
# buried bubble instead of announcing itself. Without a way out, one alert
# nobody deals with silently eats every one after it.
RSpec.describe "Buddy alert dismissal", type: :request do
  let(:user) { User.me }
  let!(:conversation) { ByteConversation.create!(user: user, mode: :buddy, buddy_theme: :byte) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def raise_alert(key, body)
    Buddy::Alerts.raise!(user: user, key: key, body: body)
  end

  it "lists what is still standing" do
    raise_alert("gate", "The gate is open")

    get buddy_alerts_path

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["alerts"].pluck("body")).to eq(["The gate is open"])
  end

  it "lets go of one and answers with what's left" do
    alert = raise_alert("gate", "The gate is open")
    raise_alert("garage", "Garage is open")

    post buddy_alert_dismiss_path(alert.id)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["alerts"].pluck("key")).to eq(["garage"])
    expect(alert.reload).to be_status_dismissed
  end

  it "404s on one that is already closed rather than pretending" do
    alert = raise_alert("gate", "The gate is open")
    Buddy::Alerts.resolve!(user: user, key: "gate")

    post buddy_alert_dismiss_path(alert.id)

    expect(response).to have_http_status(:not_found)
  end

  it "cannot reach somebody else's" do
    other = create(:user)
    ByteConversation.create!(user: other, mode: :buddy, buddy_theme: :byte)
    theirs = Buddy::Alerts.raise!(user: other, key: "gate", body: "Their gate is open")

    post buddy_alert_dismiss_path(theirs.id)

    expect(response).to have_http_status(:not_found)
    expect(theirs.reload).to be_status_open
  end
end
