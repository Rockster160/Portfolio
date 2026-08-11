require "rails_helper"

# `send_to` delivered to `primary_push_sub` — the single newest-registered
# subscription — so somebody with a phone and a desktop PWA got their
# notifications on exactly one of them, whichever they'd most recently opened.
# Opening Byte on the Mac silently took the phone off the list, and relay
# messages stopped arriving on the device that actually goes everywhere.
RSpec.describe WebPushNotifications do
  let(:user) { create(:user) }

  let!(:phone) {
    UserPushSubscription.create!(
      user: user, channel: :byte, endpoint: "https://push/phone",
      p256dh: "k", auth: "a", registered_at: 2.days.ago
    )
  }
  let!(:desk) {
    UserPushSubscription.create!(
      user: user, channel: :byte, endpoint: "https://push/desk",
      p256dh: "k", auth: "a", registered_at: Time.current
    )
  }

  # Rails.env.development? short-circuits send_to with a puts, so these run as
  # test env — which is what the suite is.
  def endpoints_pushed
    sent = []
    allow(WebPush).to receive(:payload_send) { |args| sent << args[:endpoint] }
    yield
    sent
  end

  it "reaches every registered device, not just the newest" do
    sent = endpoints_pushed {
      described_class.send_to(user, { title: "hi" }, channel: :byte)
    }

    expect(sent).to contain_exactly("https://push/phone", "https://push/desk")
  end

  it "can be narrowed to specific devices" do
    sent = endpoints_pushed {
      described_class.send_to(user, { title: "hi" }, channel: :byte, subscriptions: [phone])
    }

    expect(sent).to eq(["https://push/phone"])
  end

  it "leaves other channels' devices alone" do
    UserPushSubscription.create!(
      user: user, channel: :jarvis, endpoint: "https://push/jarvis",
      p256dh: "k", auth: "a", registered_at: Time.current
    )

    sent = endpoints_pushed {
      described_class.send_to(user, { title: "hi" }, channel: :byte)
    }

    expect(sent).not_to include("https://push/jarvis")
  end

  it "skips a device whose registration was revoked" do
    phone.update!(registered_at: nil)

    sent = endpoints_pushed {
      described_class.send_to(user, { title: "hi" }, channel: :byte)
    }

    expect(sent).to eq(["https://push/desk"])
  end

  # One dead endpoint used to be the whole notification. It has to cost only
  # itself.
  describe "when one device is gone" do
    before do
      allow(SlackNotifier).to receive(:notify)
      gone = instance_double(Net::HTTPGone, body: "gone", code: "410", message: "Gone")
      allow(WebPush).to receive(:payload_send) { |args|
        raise WebPush::ExpiredSubscription.new(gone, "push") if args[:endpoint] == "https://push/phone"
      }
    end

    it "still delivers to the others" do
      expect(WebPush).to receive(:payload_send).with(hash_including(endpoint: "https://push/desk"))

      described_class.send_to(user, { title: "hi" }, channel: :byte)
    end

    it "retires only the dead one" do
      described_class.send_to(user, { title: "hi" }, channel: :byte)

      expect(phone.reload.registered_at).to be_nil
      expect(desk.reload.registered_at).to be_present
    end

    it "still reports success, because somebody got it" do
      expect(described_class.send_to(user, { title: "hi" }, channel: :byte)).to eq("Push success")
    end
  end

  it "says so when there is nowhere to send" do
    phone.update!(registered_at: nil)
    desk.update!(registered_at: nil)

    expect(Rails.logger).to receive(:warn).with(/no registered subscription/)
    described_class.send_to(user, { title: "hi" }, channel: :byte)
  end
end
