require "rails_helper"

# Prod 3586. Chelsea asked Rocco, through Moss, whether he wanted to watch
# something while they ate. He came back to it twenty minutes later, tapped
# "yes", and got "Couldn't do that just now — tap to try again" — every time,
# forever, because the action had expired ten minutes after it was asked.
#
# Two things were wrong and each hid the other: the card had a ten-minute fuse
# it had no business having, and the client was never told, so it rendered as
# perfectly live. Every earlier relayed question happened to be answered inside
# nine minutes, so nothing had ever reached the fuse.
RSpec.describe "Buddy relayed questions don't expire" do
  let(:asker)   { create(:user) }
  let(:partner) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: asker) }
  let!(:asker_convo) {
    asker.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current)
  }
  let!(:partner_convo) {
    partner.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::WebPushNotifications).to receive(:update_count)
    ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
    asker.update!(chore_household_id: household.id)
    partner.update!(chore_household_id: household.id)
  end

  def ask!
    relay = BuddyRelay.create!(
      from_user: asker, to_user: partner, from_conversation: asker_convo,
      kind: :ask_choice, body: "Will you watch Apothecary while we eat?",
      options: %w[yes no], status: :pending
    )
    Buddy::CompanionRelay.deliver!(relay)
    relay
  end

  def action_for(relay)
    ByteAction.find_by(tool_name: "buddy_relay_answer", user_id: relay.to_user_id)
  end

  it "leaves the question open with no fuse on it" do
    action = action_for(ask!)

    expect(action.expires_at).to be_nil
  end

  # The specific failure: twenty minutes later, the tap still works.
  it "still answers long after the old ten-minute window" do
    relay  = ask!
    action = action_for(relay)

    travel_to(25.minutes.from_now) do
      expect(action.reload).to be_pending
      expect(ByteAction.active).to include(action)
    end
  end

  it "still counts as active a day later" do
    action = action_for(ask!)

    travel_to(1.day.from_now) { expect(ByteAction.active).to include(action) }
  end

  # The client greys stale rows off `action_expires_at` and nothing else. This
  # path was the only one of the three that never sent it, so an expired card
  # looked live right up until the tap came back refused.
  it "tells the client what it knows about the expiry" do
    ask!
    card = partner_convo.byte_messages.where("metadata->>'tool_name' = 'buddy_relay_answer'").last

    expect(card.metadata).to have_key("action_expires_at")
    expect(card.metadata["action_expires_at"]).to be_nil
  end

  # The default is still the default. Nothing else loses its fuse, because the
  # reason for it — a forgotten action wedging a Claude turn — is real.
  describe "everything else" do
    it "keeps the ten-minute default" do
      action = ByteAction.create!(
        user: asker, byte_conversation: asker_convo, kind: :custom,
        tool_name: "something_else", buttons: [], multi_select: false
      )

      expect(action.expires_at).to be_within(5.seconds).of(ByteAction::DEFAULT_TTL.from_now)
    end

    # A caller-supplied nil is indistinguishable from silence under `||=`, which
    # is precisely how the relay card ended up on a fuse. The flag is what says
    # it out loud.
    it "isn't fooled by an explicit nil" do
      action = ByteAction.create!(
        user: asker, byte_conversation: asker_convo, kind: :custom,
        tool_name: "something_else", buttons: [], multi_select: false, expires_at: nil
      )

      expect(action.expires_at).to be_present
    end

    it "still honours an explicit expiry" do
      action = ByteAction.create!(
        user: asker, byte_conversation: asker_convo, kind: :custom,
        tool_name: "something_else", buttons: [], multi_select: false,
        expires_at: 2.hours.from_now
      )

      expect(action.expires_at).to be_within(5.seconds).of(2.hours.from_now)
    end
  end
end
