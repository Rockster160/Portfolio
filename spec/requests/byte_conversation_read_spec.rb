require "rails_helper"

# Reading a thread is one event, not one per screen. Dismissing the same
# conversation on the phone, then the tablet, then the desk browser was the
# complaint; the second and third dismissals said nothing the first one hadn't.
RSpec.describe "Byte conversation read", type: :request do
  let(:user) { User.me }
  let(:conversation) { ByteConversation.create!(user: user, buddy_theme: :byte) }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def broadcasts
    captured = []
    allow(MonitorChannel).to receive(:broadcast_to) { |_target, payload| captured << payload }
    post byte_read_conversation_path(id: conversation.id)
    captured
  end

  it "tells every other device the thread has been read" do
    payload = broadcasts.find { |p| p.dig(:data, :kind) == :conversation_read }

    expect(payload).to be_present
    expect(payload.dig(:data, :conversation_id)).to eq(conversation.id)
  end

  it "carries the new total so a listening device can restamp the icon" do
    payload = broadcasts.find { |p| p.dig(:data, :kind) == :conversation_read }

    expect(payload.dig(:data, :unread_total)).to eq(ByteConversation.unread_total_for(user))
  end

  # The record didn't change, and a device that is LOOKING at this thread must
  # not redraw its header because another one tapped into it.
  it "does not send the conversation wire object" do
    payload = broadcasts.find { |p| p.dig(:data, :kind) == :conversation_read }

    expect(payload[:data]).not_to have_key(:conversation)
  end

  it "still moves the read marker" do
    expect { post byte_read_conversation_path(id: conversation.id) }
      .to change { conversation.reload.last_read_at }.from(nil)
  end

  it "says nothing about a conversation that isn't theirs" do
    other = ByteConversation.create!(user: create(:user), buddy_theme: :byte)

    post byte_read_conversation_path(id: other.id)
    expect(response).to have_http_status(:not_found)
  end

  # The socket only reaches screens that are RUNNING. A phone in a pocket gets
  # nothing, so its home-screen badge kept the number for a message already read
  # at the desk — the complaint that came back after the broadcast above was
  # already working. Only a push can paint the icon of a closed app.
  describe "the badge on a device that isn't running" do
    let!(:phone) {
      UserPushSubscription.create!(
        user: user, channel: :byte, endpoint: "https://push/phone",
        p256dh: "k", auth: "a", registered_at: Time.current
      )
    }

    def pushed
      sent = []
      allow(WebPush).to receive(:payload_send) { |args| sent << JSON.parse(args[:message]) }
      post byte_read_conversation_path(id: conversation.id)
      sent
    end

    it "pushes the new count so the badge can clear" do
      expect(pushed.first&.dig("data", "count")).to eq(0)
    end

    # A banner every time another device is opened would be worse than the
    # stale badge.
    it "says nothing out loud" do
      sent = pushed.first

      expect(sent["title"]).to be_blank
      expect(sent["body"]).to be_blank
    end
  end
end
