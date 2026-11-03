require "rails_helper"

# A clock reminder aimed at someone else in the household: it stays the
# setter's row, and fires as a relay from them.
RSpec.describe "a reminder set for someone else" do
  let(:household) { create(:chore_household) }
  let(:rocco)     { create(:user) }
  let(:chelsea)   { create(:user) }
  let(:seeds)     { [] }
  let!(:convo)    { rocco.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }
  let!(:hers)     { chelsea.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current) }
  let(:msg)       { convo.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: "ok") }
  let(:soon)      { 10.minutes.from_now.in_time_zone(rocco.timezone) }

  before do
    ChoreHouseholdMembership.create!(chore_household: household, user: rocco,   role: :manager)
    ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :manager)
    rocco.update_column(:chore_household_id, household.id)
    chelsea.update_column(:chore_household_id, household.id)
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt) { |args| seeds << args }
    allow(Buddy::CompanionDelivery).to receive(:deliver_plain)
  end

  def schedule(payload)
    Buddy::ProposalBuilder.create(
      user: rocco, byte_message: msg,
      markers: [{ tool_name: :schedule_reminder, payload: payload, span: [0, 0] }]
    )
  end

  describe "setting it" do
    it "records who it's for, on the setter's own row, and says so on the receipt", :aggregate_failures do
      schedule(text: "we need to remind mom about the puppy", at: soon.iso8601, notify: chelsea.first_name)

      reminder = BuddyReminder.last
      expect(reminder.notify_user_id).to eq(chelsea.id)
      # Still Rocco's row - he set it, so it's his to see and cancel.
      expect(reminder.user_id).to eq(rocco.id)
      expect(convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last.body).to include(chelsea.first_name)
    end

    it "leaves an ordinary reminder, or one naming themselves, aimed at no one else", :aggregate_failures do
      schedule(text: "check the oven", at: soon.iso8601)
      expect(BuddyReminder.last.notify_user_id).to be_nil

      schedule(text: "check the stove", at: soon.iso8601, notify: "me")
      expect(BuddyReminder.last.notify_user_id).to be_nil
    end

    # Quietly falling back to the asker is the exact failure this argument
    # exists to prevent, so an unplaceable name is refused.
    it "refuses a name it can't place rather than defaulting to the asker" do
      tool = Buddy::Tools[:schedule_reminder]
      ctx  = Buddy::ToolContext.new(rocco, conversation: convo)

      expect { tool[:confirm].call({ text: "x", at: soon.iso8601, notify: "Blorp" }, ctx) }.to raise_error(/Blorp/)
    end

    # Two people can legitimately need the same nudge at the same minute.
    it "doesn't call a reminder for someone else a duplicate of one for themselves" do
      schedule(text: "leave for the airport", at: soon.iso8601)

      expect { schedule(text: "leave for the airport", at: soon.iso8601, notify: chelsea.first_name) }.to change(BuddyReminder, :count).by(1)
    end
  end

  describe "when it fires" do
    def fire!(notify: chelsea)
      reminder = BuddyReminder.create!(
        user: rocco, byte_conversation: convo, notify_user: notify,
        body: "we need to remind mom about the puppy", fire_at: 1.minute.ago
      )
      Buddy::ReminderFirer.fire!(reminder)
      reminder
    end

    # A reminder aimed at somebody else is a message from the person who set it,
    # just one that leaves later - so it goes out bridged, like message_partner,
    # and leaves him the copy that says it went.
    it "reaches her as a relay from him, in her thread, with his copy, and closes the reminder", :aggregate_failures do
      reminder = fire!

      relay = BuddyRelay.last
      expect(relay).to have_attributes(from_user: rocco, to_user: chelsea, status: "delivered")
      expect(relay.body).to eq("we need to remind mom about the puppy")

      hers_copy = chelsea.byte_messages.where("metadata->>'kind' = 'buddy_relay'").last
      expect(hers_copy.byte_conversation).to eq(hers)
      expect(hers_copy.body).to eq("we need to remind mom about the puppy")
      expect(hers_copy.metadata.dig("relay_peer", "name")).to be_present

      copy = rocco.byte_messages.where("metadata->>'source' = 'relay_copy'").last
      expect(copy.body).to eq("we need to remind mom about the puppy")
      expect(reminder.reload.fired_at).to be_present
    end

    it "delivers to the asker as usual when it's their own" do
      reminder = BuddyReminder.create!(
        user: rocco, byte_conversation: convo, body: "check the oven", fire_at: 1.minute.ago,
      )

      expect { Buddy::ReminderFirer.fire!(reminder) }.not_to change(BuddyRelay, :count)
      expect(Buddy::CompanionDelivery).to have_received(:deliver_plain).with(hash_including(user: rocco))
    end
  end

  it "shows on the panel row who it's going to" do
    BuddyReminder.create!(
      user: rocco, byte_conversation: convo, notify_user: chelsea,
      body: "remind mom about the puppy", fire_at: soon
    )

    row = Buddy::ReminderPresenter.rows(rocco).first
    expect(row[:sublabel]).to include(chelsea.first_name)
  end
end
