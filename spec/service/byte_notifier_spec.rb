require "rails_helper"

# Presence suppression exists so a message you're already looking at doesn't
# also buzz your phone. The question this file settles is which messages are
# exempt from it.
RSpec.describe ByteNotifier do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  # A real subscription, because "which devices get this" is now part of the
  # answer — notify picks the devices to send to rather than deciding a single
  # yes/no for the whole account.
  let!(:device) {
    UserPushSubscription.create!(
      user: user, channel: :byte, endpoint: "https://web.push.apple.com/only",
      p256dh: "key", auth: "auth", registered_at: Time.current
    )
  }

  before do
    allow(WebPushNotifications).to receive(:send_to_byte)
    # Presence is stubbed at the cache rather than at a predicate: the test
    # store doesn't persist, and the thing being pinned down is which devices
    # come out of it.
    allow(Rails.cache).to receive(:read).and_return(nil)
  end

  def looking(*subs)
    subs.each { |sub|
      allow(Rails.cache).to receive(:read)
        .with(ByteController.presence_key(user, sub)).and_return(Time.current.to_i)
    }
  end

  def present!
    looking(device)
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

  # `byte_worker.js` has always read `data.count` and called `setAppBadge`;
  # nothing ever sent it, so the number on the iOS home-screen icon was
  # permanently absent. The push is the only thing that runs while the app is
  # closed, which is exactly when the badge is the whole point.
  describe "the home-screen badge count" do
    it "rides along with every push" do
      convo.update!(last_read_at: 1.hour.ago)
      deliver({ "kind" => "buddy" })

      expect(WebPushNotifications).to have_received(:send_to_byte)
        .with(hash_including(data: { count: 1 }))
    end

    it "counts every thread, not just the one that fired" do
      convo.update!(last_read_at: 1.hour.ago)
      other = user.byte_conversations.create!(mode: :claude, name: "Work", last_read_at: 1.hour.ago)
      other.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "x")

      deliver({ "kind" => "buddy" })

      expect(WebPushNotifications).to have_received(:send_to_byte)
        .with(hash_including(data: { count: 2 }))
    end
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
  # A phone and a desktop, the shape that was broken: `send_to` only ever
  # delivered to the newest-registered subscription, so opening Byte on the Mac
  # silently took the phone off the list entirely.
  describe "with more than one device" do
    let!(:desk) {
      UserPushSubscription.create!(
        user: user, channel: :byte, endpoint: "https://web.push.apple.com/desk",
        p256dh: "key", auth: "auth", registered_at: Time.current
      )
    }

    let(:pushes) { [] }

    before { allow(WebPushNotifications).to receive(:send_to_byte) { |args| pushes << args } }

    def sent_subscriptions
      pushes.last&.dig(:subscriptions)
    end

    # The reported miss: PWA open on the Mac, nothing arriving on the phone.
    it "still reaches the phone while the desktop is the one being looked at" do
      looking(desk)

      deliver({ "kind" => "buddy" })

      expect(WebPushNotifications).to have_received(:send_to_byte)
      expect(sent_subscriptions).to contain_exactly(device)
    end

    it "reaches both when neither is being looked at" do
      deliver({ "kind" => "buddy" })

      expect(sent_subscriptions).to contain_exactly(device, desk)
    end

    it "stays quiet only when every device is looking" do
      looking(device, desk)

      deliver({ "kind" => "buddy" })

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    # A reminder or a relay goes everywhere regardless — being sat in front of
    # one screen says nothing about whether they'll see something they never
    # asked for.
    it "reaches every device for a self-initiated nudge, present or not" do
      looking(device, desk)

      deliver({ "kind" => "buddy", "self_initiated" => true }, body: "⏰ time to go")

      expect(sent_subscriptions).to contain_exactly(device, desk)
    end

    it "doesn't claim presence for someone with no Byte subscription" do
      device.destroy!
      desk.destroy!
      allow(Rails.cache).to receive(:read).and_return(Time.current.to_i)

      expect(described_class.send(:device_present?, user)).to be(false)
    end
  end
end
