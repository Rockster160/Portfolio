require "rails_helper"

# A muted thread still fills and still shows; it just never asks for attention.
# No push from anything posted in it, and nothing in it counted as unread.
RSpec.describe "A muted conversation" do
  let(:user) { create(:user) }
  let!(:audit) {
    user.byte_conversations.create!(
      mode: :claude, name: "Daily Audit", last_message_at: 1.minute.ago, last_read_at: 1.day.ago,
      metadata: { "muted" => true },
    )
  }
  let!(:phone) {
    user.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: 1.hour.ago, last_read_at: 1.day.ago)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def message_in(convo, metadata: {})
    convo.byte_messages.create!(
      user: user, direction: :inbound, state: :delivered, body: "report ready",
      metadata: metadata, delivered_at: Time.current
    )
  end

  it "pushes nothing, whatever the message carries or however it got there" do
    ByteNotifier.notify(user, message_in(audit))
    ByteNotifier.notify(user, message_in(audit, metadata: { "self_initiated" => true }))
    ByteNotifier.notify(user, message_in(audit, metadata: { "buttons" => [{ "status" => "pending" }] }))
    Buddy::CompanionDelivery.deliver_plain(
      user: user, conversation: audit, text: "kettle's done", metadata: { "self_initiated" => true },
    )
    Buddy::CompanionRelay.send(:push, user, "Rocco: on my way", conversation: audit)

    expect(WebPushNotifications).not_to have_received(:send_to_byte)
  end

  it "still pushes the same message from a thread that isn't muted" do
    ByteNotifier.notify(user, message_in(phone, metadata: { "self_initiated" => true }))

    expect(WebPushNotifications).to have_received(:send_to_byte)
  end

  it "counts nothing as unread, in the thread or on the badge", :aggregate_failures do
    3.times { message_in(audit) }
    message_in(phone)

    expect(audit.unread_count).to eq(0)
    expect(audit.as_wire[:unread_count]).to eq(0)
    expect(ByteConversation.unread_total_for(user)).to eq(1)
  end

  it "does not hand back what arrived while it was muted when it's unmuted" do
    2.times { message_in(audit) }

    audit.update!(metadata: audit.metadata.merge("muted" => false))

    expect(audit.reload).not_to be_muted
    expect(audit.unread_count).to eq(0)
  end
end
