require "rails_helper"

# Every subscription is created with `userVisibleOnly: true`, which promises the
# browser that a push results in something the person can see. WebKit enforces
# it by revoking the SUBSCRIPTION when a worker takes a push and shows nothing.
#
# A badge-only push shows nothing by design. From 2026-09-03, when a titleless
# payload was first let through and `ByteNotifier.notify_read` began firing one
# on every read, endpoints stopped lasting weeks and started lasting minutes —
# 21 live rows piled up for one person across three real devices, and a Jarvis
# subscription that had survived since May 2024 died that same evening.
#
# So the count rides along on pushes that show something, and the only push
# spent on the badge alone is the fall to zero, once, on the edge.
RSpec.describe WebPushNotifications do
  let(:user) { create(:user) }

  let!(:sub) {
    UserPushSubscription.create!(
      user: user, channel: :byte, endpoint: "https://push/phone",
      p256dh: "k", auth: "a", registered_at: Time.current
    )
  }

  # Setup here sends real pushes at a fake key. The recorder below re-stubs on
  # top of this when a test wants to see what actually went out.
  before { allow(WebPush).to receive(:payload_send) }

  def counts_pushed
    sent = []
    allow(WebPush).to receive(:payload_send) { |args| sent << JSON.parse(args[:message]).dig("data", "count") }
    yield
    sent
  end

  describe "the fall to zero" do
    it "is worth a push of its own" do
      described_class.push_badge(user, 3, channel: :byte)

      sent = counts_pushed { described_class.push_badge(user, 0, channel: :byte) }

      expect(sent).to eq([0])
    end

    # This is the one that was killing subscriptions: a read fires on every
    # message the person looks at, and the count is already zero for all but the
    # first of them.
    it "is spent once, not on every read that follows" do
      described_class.push_badge(user, 3, channel: :byte)
      described_class.push_badge(user, 0, channel: :byte)

      sent = counts_pushed { 5.times { described_class.push_badge(user, 0, channel: :byte) } }

      expect(sent).to be_empty
    end

    # Nothing recorded is not the same as a badge known to be showing. Guessing
    # means a silent push on the first read after every deploy.
    it "is not sent when there was nothing known to clear" do
      sent = counts_pushed { described_class.push_badge(user, 0, channel: :byte) }

      expect(sent).to be_empty
    end
  end

  # A count above zero always has a notification to travel on.
  it "spends no push of its own on a count going up" do
    sent = counts_pushed { described_class.push_badge(user, 4, channel: :byte) }

    expect(sent).to be_empty
  end

  # `send_to` is what carries it in that case, so what it carried is what the
  # device now believes — and that is the edge the next clear is measured from.
  it "learns the count from a notification that carried one" do
    described_class.send_to(user, { title: "hi", data: { count: 2 } }, channel: :byte)

    sent = counts_pushed { described_class.push_badge(user, 0, channel: :byte) }

    expect(sent).to eq([0])
  end

  it "keeps channels apart, because they are different app icons" do
    described_class.push_badge(user, 3, channel: :byte)

    sent = counts_pushed { described_class.push_badge(user, 0, channel: :jarvis) }

    expect(sent).to be_empty
  end

  describe "update_count" do
    let!(:jarvis_sub) {
      UserPushSubscription.create!(
        user: user, channel: :jarvis, endpoint: "https://push/jarvis",
        p256dh: "k", auth: "a", registered_at: Time.current
      )
    }

    it "sends nothing while there are prompts waiting" do
      sent = counts_pushed { described_class.update_count(user, 2) }

      expect(sent).to be_empty
    end

    it "clears the badge once the last one is answered" do
      described_class.update_count(user, 1)

      sent = counts_pushed { described_class.update_count(user, 0) }

      expect(sent).to eq([0])
    end
  end
end
