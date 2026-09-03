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

  # Every endpoint here is web.push.apple.com, where a normal-urgency push is
  # one Apple may hold until the phone next wakes on its own. The gem defaults
  # to normal and nothing overrode it, so a message could sit delivered in the
  # thread for minutes before the buzz — and from this end the send looked
  # instant and successful, because it was.
  describe "urgency" do
    def sent_with
      captured = []
      allow(WebPush).to receive(:payload_send) { |args| captured << args }
      yield
      captured
    end

    it "marks a message as high, because somebody is waiting on it" do
      sent = sent_with { described_class.send_to(user, { title: "hi" }, channel: :byte) }

      expect(sent.pluck(:urgency)).to all(eq("high"))
    end

    # Nobody waits on a notification being taken away.
    it "lets a dismissal go at low urgency" do
      sent = sent_with { described_class.dismiss(user, "byte-1", channel: :byte) }

      expect(sent.pluck(:urgency)).to all(eq("low"))
    end

    # These sends are serial: one push service that accepts the connection and
    # never answers used to hold every device behind it, indefinitely.
    it "gives every send a finite deadline" do
      sent = sent_with { described_class.send_to(user, { title: "hi" }, channel: :byte) }

      expect(sent).to all(include(open_timeout: be_positive, read_timeout: be_positive))
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

    it "goes out at all" do
      sent = payload_sent { described_class.send_to(user, { data: { count: 0 } }, channel: :byte) }

      expect(sent).to be_present
    end

    it "carries the count the worker reads" do
      sent = payload_sent { described_class.send_to(user, { data: { count: 3 } }, channel: :byte) }

      expect(sent.dig("data", "count")).to eq(3)
    end

    # Or the phone shows a banner every time another device is opened.
    it "carries nothing to draw a notification with" do
      sent = payload_sent { described_class.send_to(user, { data: { count: 0 } }, channel: :byte) }

      expect(sent["title"]).to be_blank
      expect(sent["body"]).to be_blank
    end

    it "still drops a push with nothing in it at all" do
      sent = payload_sent { described_class.send_to(user, {}, channel: :byte) }

      expect(sent).to be_nil
    end
  end
end
