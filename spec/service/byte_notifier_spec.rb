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
    allow(described_class).to receive(:user_present?).and_return(false)
  end

  def present!
    allow(described_class).to receive(:user_present?).and_return(true)
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
end
