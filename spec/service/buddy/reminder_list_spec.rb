require "rails_helper"

# The inline "here's what you've got set" reminders list: it renders pending
# BuddyReminders + active BuddyWatches as a manage-mode ByteAction, and taps on
# it cancel / restore the underlying record.
RSpec.describe Buddy::ReminderList do
  let(:user) { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def reminder!(body:, fire_at:, recurrence: nil)
    BuddyReminder.create!(user: user, byte_conversation: convo, body: body, fire_at: fire_at, recurrence: recurrence)
  end

  def watch!(body:, scope: "travel", human: nil)
    BuddyWatch.create!(
      user: user, byte_conversation: convo, kind: "prompt", body: body,
      trigger_scope: scope, match: {}, metadata: { "human_when" => human }.compact
    )
  end

  it "exposes a registered list_reminders tool" do
    expect(Buddy::Tools[:list_reminders]).to be_present
    expect(Buddy::Tools[:list_reminders][:auto]).to be(true)
  end

  describe ".render" do
    it "builds a manage-mode action listing reminders then watches" do
      reminder!(body: "Vet appt", fire_at: 2.hours.from_now)
      reminder!(
        body: "Take trash out", fire_at: 1.day.from_now,
        recurrence: { "kind" => "weekly", "weekday" => "wednesday", "at" => "20:00" }
      )
      watch!(body: "Grab prescription", human: "when you get to Costco")

      action = described_class.render(user: user, conversation: convo)

      expect(action.tool_name).to eq(described_class::TOOL_NAME)
      expect(action.multi_select).to be(true)
      expect(action.buttons.size).to eq(3)

      types = action.buttons.pluck("record_type")
      expect(types).to eq(%w[reminder reminder watch])
      expect(action.buttons.pluck("id")).to eq([1, 2, 3])

      recurring = action.buttons.find { |b| b["label"] == "Take trash out" }
      expect(recurring["glyph"]).to eq("🔁")
      expect(recurring["sublabel"]).to include("every Wednesday")

      # The list rides on a message the client renders in manage mode.
      expect(action.byte_message.metadata["select_mode"]).to eq("manage")
      expect(action.byte_message.metadata["tool_name"]).to eq(described_class::TOOL_NAME)
    end

    it "posts a plain 'nothing set' message and no action when empty" do
      expect(described_class.render(user: user, conversation: convo)).to be_nil
      expect(ByteAction.where(user: user)).to be_empty
      expect(convo.byte_messages.last.body).to match(/don't have any reminders/i)
    end

    it "ignores cancelled reminders and fired one-shot watches" do
      reminder!(body: "Live one", fire_at: 3.hours.from_now)
      reminder!(body: "Gone", fire_at: 3.hours.from_now).update!(cancelled_at: Time.current)
      watch!(body: "Fired").update!(fired_at: Time.current)

      action = described_class.render(user: user, conversation: convo)
      expect(action.buttons.pluck("label")).to eq(["Live one"])
    end
  end

  describe ".cancel! / .restore!" do
    it "cancels the row's reminder and marks it cancelled, then restores it" do
      rem = reminder!(body: "Vet appt", fire_at: 2.hours.from_now)
      action = described_class.render(user: user, conversation: convo)
      id = action.buttons.first["id"]

      described_class.cancel!(action, id)
      expect(rem.reload.cancelled_at).to be_present
      expect(action.reload.buttons.first["status"]).to eq("cancelled")

      described_class.restore!(action, id)
      expect(rem.reload.cancelled_at).to be_nil
      expect(action.reload.buttons.first["status"]).to eq("active")
    end

    it "cancels a watch row too" do
      w = watch!(body: "Grab prescription", human: "when you get to Costco")
      action = described_class.render(user: user, conversation: convo)
      described_class.cancel!(action, action.buttons.first["id"])

      expect(w.reload.cancelled_at).to be_present
    end

    it "is a no-op for an unknown row id" do
      reminder!(body: "Vet appt", fire_at: 2.hours.from_now)
      action = described_class.render(user: user, conversation: convo)
      expect { described_class.cancel!(action, 999) }.not_to raise_error
    end

    it "never touches another user's record" do
      other = create(:user)
      other_convo = other.byte_conversations.create!(mode: :buddy)
      foreign = BuddyReminder.create!(user: other, byte_conversation: other_convo, body: "Theirs", fire_at: 2.hours.from_now)

      rem = reminder!(body: "Mine", fire_at: 2.hours.from_now)
      action = described_class.render(user: user, conversation: convo)
      # Forge a button pointing at the other user's reminder.
      action.update!(buttons: [action.buttons.first.merge("record_id" => foreign.id)])

      described_class.cancel!(action, action.buttons.first["id"])
      expect(foreign.reload.cancelled_at).to be_nil
    end
  end
end
