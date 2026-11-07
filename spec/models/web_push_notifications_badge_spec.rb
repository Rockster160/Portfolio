require "rails_helper"

# Every subscription is created with `userVisibleOnly: true`, which promises the
# browser that a push results in something the person can see. WebKit enforces
# it by revoking the SUBSCRIPTION when a worker takes a push and shows nothing,
# so a push carrying only a count, or only a dismissal, costs that device its
# notifications until the app is opened again.
RSpec.describe WebPushNotifications do
  let(:user) { create(:user) }

  let!(:sub) {
    UserPushSubscription.create!(
      user: user, channel: :byte, endpoint: "https://push/phone",
      p256dh: "k", auth: "a", registered_at: Time.current
    )
  }

  def payloads_pushed
    sent = []
    allow(WebPush).to receive(:payload_send) { |args| sent << JSON.parse(args[:message]) }
    yield
    sent
  end

  describe "a push with nothing to show" do
    it "never leaves for a bare count" do
      sent = payloads_pushed { described_class.send_to(user, { data: { count: 0 } }, channel: :byte) }

      expect(sent).to be_empty
    end

    it "never leaves for a dismissal" do
      sent = payloads_pushed {
        described_class.send_to(user, { dismiss: true, tag: "byte-1" }, channel: :byte)
      }

      expect(sent).to be_empty
    end

    it "never leaves empty" do
      sent = payloads_pushed { described_class.send_to(user, {}, channel: :byte) }

      expect(sent).to be_empty
    end
  end

  it "still carries the count on a push that shows something" do
    sent = payloads_pushed {
      described_class.send_to(user, { title: "hi", data: { count: 2 } }, channel: :byte)
    }

    expect(sent.map { |p| p.dig("data", "count") }).to eq([2])
  end

  it "goes out with a body and no title" do
    sent = payloads_pushed { described_class.send_to(user, { body: "hello" }, channel: :byte) }

    expect(sent.pluck("body")).to eq(["hello"])
  end

  describe "Jil dismiss" do
    let!(:whisper_sub) {
      UserPushSubscription.create!(
        user: user, channel: :whisper, endpoint: "https://push/whisper",
        p256dh: "k", auth: "a", registered_at: Time.current
      )
    }

    it "sends nothing from either dismiss" do
      code = <<~'JIL'
        a = PushNotification.dismiss("tag-a")::Any
        b = Whisper.dismiss("tag-b")::Any
      JIL

      sent = payloads_pushed { Jil::Executor.call(user, code) }

      expect(sent).to be_empty
    end
  end
end
