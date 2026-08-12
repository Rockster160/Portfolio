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
    it "picks the person's own thread even when the wall is newer" do
      expect(ByteConversation.for_self_initiated(user)).to eq(phone)
    end

    it "still picks the wall when it's the only thread there is" do
      phone.destroy!

      expect(ByteConversation.for_self_initiated(user)).to eq(wall)
    end

    it "ignores archived threads, same as before" do
      phone.update!(archived: true)

      expect(ByteConversation.for_self_initiated(user)).to eq(wall)
    end

    # Same failure as the kiosk and for the same reason: an eval run leaves the
    # eval thread holding the newest last_message_at.
    it "skips eval threads too" do
      user.byte_conversations.create!(
        mode: :buddy, name: "evals", last_message_at: 1.second.ago, metadata: { "eval" => true },
      )

      expect(ByteConversation.for_self_initiated(user)).to eq(phone)
    end

    it "has nowhere to go when there are no buddy threads at all" do
      user.byte_conversations.destroy_all

      expect(ByteConversation.for_self_initiated(user)).to be_nil
    end
  end

  # The briefing is the clearest case: addressed to one person, first thing they
  # read, and on the wall it would be read by whoever walked into the kitchen
  # while the person it was written for got nothing at all.
  describe "the morning briefing" do
    it "goes to their own thread, not the wall" do
      allow(Buddy::TodayBriefing).to receive(:deliver!)
      allow(Buddy::TodayScheduler).to receive(:target_time).and_return(Time.current)

      Buddy::TodayScheduler.maybe_deliver(user, Time.current)

      expect(Buddy::TodayBriefing).to have_received(:deliver!).with(user, phone, scheduled: true)
    end
  end

  describe "everything else that fires on its own" do
    it "routes relays, timers and alarms to their own thread" do
      expect(Buddy::CompanionRelay.conversation_for(user)).to eq(phone)
    end

    it "posts prompt forms to their own thread" do
      expect(Buddy::PromptDelivery.send(:conversation_for, user)).to eq(phone)
    end

    it "announces to their own thread" do
      expect(Buddy::Announce.send(:conversation_for, user)).to eq(phone)
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

    it "sends nothing for an ordinary message on the wall" do
      ByteNotifier.notify(user, message_in(wall))

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    # `always_notify?` exists to beat presence suppression for things nobody is
    # waiting on. The kiosk rule is not a presence rule and must outrank it.
    it "sends nothing even for a self-initiated message, which normally always pushes" do
      ByteNotifier.notify(user, message_in(wall, metadata: { "self_initiated" => true }))

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    it "sends nothing for a waiting checklist on the wall" do
      ByteNotifier.notify(user, message_in(wall, metadata: { "buttons" => [{ "status" => "pending" }] }))

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    it "still pushes the identical message on their own thread" do
      ByteNotifier.notify(user, message_in(phone, metadata: { "self_initiated" => true }))

      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    it "stays silent when a reminder is delivered straight onto the wall" do
      Buddy::CompanionDelivery.deliver_plain(
        user: user, conversation: wall, text: "kettle's done", metadata: { "self_initiated" => true },
      )

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    it "stays silent when a relay is aimed explicitly at the wall" do
      Buddy::CompanionRelay.send(:push, user, "Rocco: on my way", conversation: wall)

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end
  end

  # A number on the home screen means "something is waiting for you". A routine
  # somebody already tapped in the kitchen is not waiting for anyone.
  describe "the iOS home-screen badge" do
    before do
      phone.update!(last_read_at: 1.day.ago)
      wall.update!(last_read_at: 1.day.ago)
    end

    it "leaves the wall's traffic out of the count" do
      3.times { wall.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

      expect(ByteConversation.unread_total_for(user)).to eq(0)
    end

    it "still counts their own threads" do
      phone.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok")

      expect(ByteConversation.unread_total_for(user)).to eq(1)
    end

    # Nothing is hidden — the drawer still shows the wall has been busy. It just
    # doesn't follow anyone out of the house.
    it "keeps the per-thread count intact so the drawer still shows it" do
      wall.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok")

      expect(wall.unread_count).to eq(1)
    end
  end
end
