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
    let(:gone) { instance_double(Net::HTTPGone, body: "gone", code: "410", message: "Gone") }

    before { allow(SlackNotifier).to receive(:notify) }

    it "still delivers to the others, retires only the dead one, and reports success" do
      sent = []
      allow(WebPush).to receive(:payload_send) { |args|
        raise WebPush::ExpiredSubscription.new(gone, "push") if args[:endpoint] == "https://push/phone"

        sent << args[:endpoint]
      }

      expect(described_class.send_to(user, { title: "hi" }, channel: :byte)).to eq("Push success")

      expect(sent).to eq(["https://push/desk"])
      expect(phone.reload.registered_at).to be_nil
      expect(desk.reload.registered_at).to be_present
    end
  end

  # Every endpoint here is web.push.apple.com, where a normal-urgency push is
  # one Apple may hold until the phone next wakes on its own.
  describe "urgency" do
    def sent_with
      captured = []
      allow(WebPush).to receive(:payload_send) { |args| captured << args }
      yield
      captured
    end

    # These sends are serial, so each one also needs a finite deadline or one
    # push service that never answers holds every device behind it.
    it "marks a message as high, with a finite deadline on every send" do
      sent = sent_with { described_class.send_to(user, { title: "hi" }, channel: :byte) }

      expect(sent.pluck(:urgency)).to all(eq("high"))
      expect(sent).to all(include(open_timeout: be_positive, read_timeout: be_positive))
    end

    # Nobody waits on a notification being taken away.
    it "lets a dismissal go at low urgency" do
      sent = sent_with { described_class.dismiss(user, "byte-1", channel: :byte) }

      expect(sent.pluck(:urgency)).to all(eq("low"))
    end

    it "keeps a timed-out device registered, since a timeout proves nothing" do
      allow(WebPush).to receive(:payload_send).and_raise(Net::ReadTimeout)

      expect { described_class.send_to(user, { title: "hi" }, channel: :byte) }.not_to raise_error
      expect(phone.reload.registered_at).to be_present
    end
  end

  # A push with no title is SILENT, and there are two worth sending: a
  # dismissal, and a bare count. The count is the only thing that can paint the
  # home-screen icon of an app that isn't running — so reading a thread on the
  # desk browser left the phone wearing a badge for a message already read,
  # sometimes for days. `byte_worker.js` has always handled this shape (clears
  # on zero, shows no banner without a title); nothing ever reached it, because
  # the titleless guard dropped every one before it was sent.
  describe "a silent count-only push" do
    def payload_sent
      sent = nil
      allow(WebPush).to receive(:payload_send) { |args| sent = JSON.parse(args[:message]) }
      yield
      sent
    end

    it "goes out carrying the count the worker reads and nothing to draw a banner with" do
      sent = payload_sent { described_class.send_to(user, { data: { count: 3 } }, channel: :byte) }

      expect(sent.dig("data", "count")).to eq(3)
      expect(sent["title"]).to be_blank
      expect(sent["body"]).to be_blank
    end

    it "still drops a push with nothing in it at all" do
      sent = payload_sent { described_class.send_to(user, {}, channel: :byte) }

      expect(sent).to be_nil
    end
  end
end
