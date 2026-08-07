require "rails_helper"

# Presence suppression exists so a message you're already looking at doesn't
# also buzz your phone. The question this file settles is which messages are
# exempt from it.
RSpec.describe ByteNotifier do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  before do
    allow(WebPushNotifications).to receive(:send_to_byte)
    # Stubbed rather than written to the cache: the test store doesn't persist,
    # and the branch being pinned down here is "what is exempt from presence",
    # not how presence itself is recorded.
    allow(described_class).to receive(:device_present?).and_return(false)
  end

  def present!
    allow(described_class).to receive(:device_present?).and_return(true)
  end

  def deliver(metadata, body: "hey", state: :delivered)
    msg = convo.byte_messages.create!(
      user: user, direction: :inbound, state: state, body: body, metadata: metadata,
    )
    described_class.notify(user, msg)
    msg
  end

  it "pushes an ordinary reply when the app isn't open" do
    deliver({ "kind" => "buddy" })

    expect(WebPushNotifications).to have_received(:send_to_byte)
  end

  it "stays quiet on an ordinary reply while the app is open" do
    present!

    deliver({ "kind" => "buddy" })

    expect(WebPushNotifications).not_to have_received(:send_to_byte)
  end

  # A reminder, a watch tripping, the morning briefing. The person didn't ask
  # for it and isn't watching for it, so "the app is open" says nothing about
  # whether they'll see it. Buddy::CompanionDelivery#deliver_plain has always
  # ignored presence for these; the prompt path routes through a Buddy turn and
  # was losing that, so reminders arrived silently.
  it "pushes a self-initiated nudge even while the app is open" do
    present!

    deliver({ "kind" => "buddy", "self_initiated" => true }, body: "⏰ put your Loops away")

    expect(WebPushNotifications).to have_received(:send_to_byte)
  end

  it "pushes a waiting checklist even while the app is open" do
    present!

    deliver({
      "kind"      => "buddy_reply",
      "tool_name" => "buddy_proposals",
      "buttons"   => [{ "id" => 1, "status" => "pending" }],
    })

    expect(WebPushNotifications).to have_received(:send_to_byte)
  end

  it "never pushes a message that is still streaming" do
    deliver({ "kind" => "buddy" }, state: :streaming)

    expect(WebPushNotifications).not_to have_received(:send_to_byte)
  end

  # Presence has to be about the ONE device the push would land on. Asked about
  # the person instead, a browser tab open at the desk — a tab with no push
  # subscription, that could never have shown the notification — silenced the
  # phone. Prod Aug 7: a "Tick" typed from the CLI got a reply that never
  # notified, while a push sent directly to the same subscription arrived fine.
  describe "which device counts as present" do
    let!(:phone) {
      UserPushSubscription.create!(
        user: user, channel: :byte, endpoint: "https://web.push.apple.com/phone",
        p256dh: "key", auth: "auth", registered_at: Time.current,
      )
    }

    before { allow(described_class).to receive(:device_present?).and_call_original }

    def looking(sub)
      allow(Rails.cache).to receive(:read).and_return(nil)
      allow(Rails.cache).to receive(:read)
        .with(ByteController.presence_key(user, sub)).and_return(Time.current.to_i)
    end

    it "stays quiet when the device that would receive it is the one looking" do
      looking(phone)

      deliver({ "kind" => "buddy" })

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    it "still pushes when some OTHER window is the one that's open" do
      desk = UserPushSubscription.create!(
        user: user, channel: :byte, endpoint: "https://web.push.apple.com/desk",
        p256dh: "key", auth: "auth", registered_at: 1.day.ago,
      )
      looking(desk)

      deliver({ "kind" => "buddy" })

      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    it "pushes when nothing is looking at all" do
      allow(Rails.cache).to receive(:read).and_return(nil)

      deliver({ "kind" => "buddy" })

      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    it "doesn't claim presence for someone with no Byte subscription" do
      phone.destroy!
      allow(Rails.cache).to receive(:read).and_return(Time.current.to_i)

      expect(described_class.send(:device_present?, user)).to be(false)
    end
  end
end
