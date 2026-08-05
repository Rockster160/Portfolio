require "rails_helper"

# Prod 2547: "Send a reminder to Chelsea in 10 minutes that we need to remind
# mom to remember puppy!" set an ordinary reminder and pinged Rocco. There was
# no way to aim a clock reminder at anyone - `remind_when` had `notify` and
# `schedule_reminder` didn't - so the closest available thing was the wrong
# thing, and the person who was supposed to act never heard about it.
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
    it "records who it's for instead of aiming it back at the asker" do
      schedule(text: "we need to remind mom about the puppy", at: soon.iso8601, notify: chelsea.first_name)

      reminder = BuddyReminder.last
      expect(reminder.notify_user_id).to eq(chelsea.id)
      # Still Rocco's row - he set it, so it's his to see and cancel.
      expect(reminder.user_id).to eq(rocco.id)
    end

    it "says who it's for on the receipt, not just that it's set" do
      schedule(text: "remind mom about the puppy", at: soon.iso8601, notify: chelsea.first_name)

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include(chelsea.first_name)
      expect(chip.body).not_to match(/remind you|send you/i)
    end

    it "leaves an ordinary reminder alone" do
      schedule(text: "check the oven", at: soon.iso8601)

      expect(BuddyReminder.last.notify_user_id).to be_nil
    end

    it "treats naming themselves as an ordinary reminder" do
      schedule(text: "check the oven", at: soon.iso8601, notify: "me")

      expect(BuddyReminder.last.notify_user_id).to be_nil
    end

    # Quietly falling back to the asker is the exact failure this argument
    # exists to prevent, so an unplaceable name is refused.
    it "refuses a name it can't place rather than defaulting to the asker" do
      tool = Buddy::Tools[:schedule_reminder]
      ctx  = Buddy::ToolContext.new(rocco, conversation: convo)

      expect { tool[:confirm].call({ text: "x", at: soon.iso8601, notify: "Blorp" }, ctx) }
        .to raise_error(/not sure who Blorp is/i)
    end

    # Two people can legitimately need the same nudge at the same minute.
    it "doesn't call a reminder for someone else a duplicate of one for themselves" do
      schedule(text: "leave for the airport", at: soon.iso8601)

      expect { schedule(text: "leave for the airport", at: soon.iso8601, notify: chelsea.first_name) }
        .to change(BuddyReminder, :count).by(1)
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

    it "lands on the recipient's own companion, not the asker's" do
      fire!

      expect(seeds.length).to eq(1)
      expect(seeds.first[:user]).to eq(chelsea)
      expect(seeds.first[:conversation]).to eq(hers)
    end

    it "attributes it, so her companion passes it on instead of answering it" do
      fire!

      seed = seeds.first[:seed]
      expect(seed).to include(rocco.first_name)
      expect(seed).to include("we need to remind mom about the puppy")
      expect(seed).to include("passing it along")
    end

    it "still closes the reminder out" do
      reminder = fire!

      expect(reminder.reload.fired_at).to be_present
    end

    it "delivers to the asker as usual when it's their own" do
      reminder = BuddyReminder.create!(
        user: rocco, byte_conversation: convo, body: "check the oven", fire_at: 1.minute.ago,
      )
      Buddy::ReminderFirer.fire!(reminder)

      expect(Buddy::CompanionDelivery).to have_received(:deliver_plain).with(hash_including(user: rocco))
      expect(seeds).to be_empty
    end
  end

  it "shows on the panel row who it's for" do
    BuddyReminder.create!(
      user: rocco, byte_conversation: convo, notify_user: chelsea,
      body: "remind mom about the puppy", fire_at: soon
    )

    row = Buddy::ReminderPresenter.rows(rocco).first
    expect(row[:sublabel]).to start_with("for #{chelsea.first_name} · ")
  end
end
