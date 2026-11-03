require "rails_helper"

# The wall tablet is a screen in a room. Everything else Byte runs on is a
# device that follows one person around, and the whole of this file is the
# difference between those two things.
#
# Two guarantees, and they're independent on purpose:
#
#   * Nothing on the kiosk thread ever pushes. Somebody standing in the kitchen
#     tapping a routine must not buzz a phone upstairs.
#   * Nothing addressed to a PERSON — the morning briefing, a reminder, a relay
#     from their partner — lands on the kiosk. "Newest Buddy thread" is how
#     every one of those picks its destination, and a tablet in daily use is
#     permanently the newest thread.
#
# The second is what makes the first safe to state so bluntly: if the wall never
# receives anything personal, silencing it costs nothing.
RSpec.describe "Buddy kiosk isolation" do
  let(:user) { create(:user) }

  # Deliberately the NEWER of the two, because that's the shape that breaks:
  # every picker in the app orders by last_message_at, so the wall wins on
  # recency the moment anyone touches it.
  let!(:phone) {
    user.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: 2.hours.ago)
  }
  let!(:wall) {
    user.byte_conversations.create!(
      mode: :buddy, name: "Glimmer", last_message_at: 1.minute.ago, metadata: { "kiosk" => true },
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  describe "where an unasked-for message goes" do
    # An eval run leaves the eval thread holding the newest last_message_at,
    # the same failure as the kiosk.
    it "picks the person's own thread over a newer wall or eval thread", :aggregate_failures do
      user.byte_conversations.create!(
        mode: :buddy, name: "evals", last_message_at: 1.second.ago, metadata: { "eval" => true },
      )

      expect(ByteConversation.for_self_initiated(user)).to eq(phone)
      expect(Buddy::TodaySchedule.ensure!(user).byte_conversation).to eq(phone)
      expect(Buddy::CompanionRelay.conversation_for(user)).to eq(phone)
      expect(Buddy::PromptDelivery.send(:conversation_for, user)).to eq(phone)
      expect(Buddy::Announce.send(:conversation_for, user)).to eq(phone)
    end

    it "falls back to the wall when it's the only live thread, and to nothing without one", :aggregate_failures do
      phone.update!(archived: true)
      expect(ByteConversation.for_self_initiated(user)).to eq(wall)

      phone.destroy!
      expect(ByteConversation.for_self_initiated(user)).to eq(wall)

      user.byte_conversations.destroy_all
      expect(ByteConversation.for_self_initiated(user)).to be_nil
    end
  end

  describe "pushes off the wall" do
    before { allow(WebPushNotifications).to receive(:send_to_byte) }

    def message_in(convo, metadata: {})
      convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "dinner started",
        metadata: metadata, delivered_at: Time.current
      )
    end

    # `always_notify?` exists to beat presence suppression for things nobody is
    # waiting on. The kiosk rule is not a presence rule and must outrank it.
    it "sends nothing from the wall, however the message got there or whatever it carries" do
      ByteNotifier.notify(user, message_in(wall))
      ByteNotifier.notify(user, message_in(wall, metadata: { "self_initiated" => true }))
      ByteNotifier.notify(user, message_in(wall, metadata: { "buttons" => [{ "status" => "pending" }] }))
      Buddy::CompanionDelivery.deliver_plain(
        user: user, conversation: wall, text: "kettle's done", metadata: { "self_initiated" => true },
      )
      Buddy::CompanionRelay.send(:push, user, "Rocco: on my way", conversation: wall)

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    it "still pushes the identical message on their own thread" do
      ByteNotifier.notify(user, message_in(phone, metadata: { "self_initiated" => true }))

      expect(WebPushNotifications).to have_received(:send_to_byte)
    end
  end

  # A routine somebody already tapped in the kitchen is not waiting for anyone,
  # but the drawer still shows the wall has been busy.
  it "leaves the wall's traffic out of the home-screen badge but keeps its own count", :aggregate_failures do
    phone.update!(last_read_at: 1.day.ago)
    wall.update!(last_read_at: 1.day.ago)
    3.times { wall.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }
    phone.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok")

    expect(ByteConversation.unread_total_for(user)).to eq(1)
    expect(wall.unread_count).to eq(3)
  end
end
