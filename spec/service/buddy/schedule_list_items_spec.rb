require "rails_helper"

# Prod 4744-4750, 26 Aug. "Every night at 9pm, can you add these items to that
# list: ..." → a claim that never ran, and then, asked again, "I can't make list
# items recur on a schedule, so I've put that request on the list instead."
#
# Adding a list item is something Buddy does. Putting a thing on the clock is
# something Buddy does. `BuddyReminder#action` has stored `{tool:, payload:}`
# and fired it with no model turn behind it since `schedule_function` was
# built — and `add_list_item`'s own IMMEDIATE_NOTE already tells the model to
# reach for "a schedule_* tool when they named a clock time". Every piece was
# there and nothing joined them, so the answer to a recurring list add was a
# feature request.
#
# The first attempt at this built a per-user Jil function and scheduled that,
# which is the wrong shape twice: it makes a plain capability into a custom
# automation each person has to have, and it routes a list write out through the
# automation engine to reach a tool sitting right there. He said so.
RSpec.describe "schedule_list_items" do
  let(:user) { create(:user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let!(:list) { user.lists.create!(name: "Before Bed") }
  let(:ctx) { Buddy::ToolContext.new(user, conversation: convo) }
  let(:tool) { Buddy::Tools[:schedule_list_items] }
  let(:three) { "Pickup Whisper Dinner\nKitchen & Living 90% Reset\nDish washer running/delay" }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::WebPushNotifications).to receive(:update_count)
  end

  def schedule!(payload={})
    args = { list: "Before Bed", items: three, repeat: "daily:21:00" }.merge(payload)
    BuddyReminder.find(tool[:execute].call(args.merge(tool[:confirm].call(args, ctx)[:resolved]), ctx)[:reminder_id])
  end

  describe "putting them on the clock" do
    it "stores one call per item rather than adding anything now" do
      reminder = schedule!

      expect(list.reload.list_items).to be_empty
      expect(reminder.action.length).to eq(3)
      expect(reminder.action.pluck("tool").uniq).to eq(["add_list_item"])
      expect(reminder.action.pluck("payload").pluck("item")).to eq(
        ["Pickup Whisper Dinner", "Kitchen & Living 90% Reset", "Dish washer running/delay"],
      )
    end

    # The same reason `schedule_function` stores a function NAME rather than an
    # id: this row repeats nightly for months, and a list that gets rebuilt or
    # renamed under it must fail loudly at 9pm rather than write into a dead id.
    it "stores the raw arguments, so everything re-resolves when it fires" do
      stored = schedule!.action.first["payload"]

      expect(stored).to include("list" => "Before Bed", "item" => "Pickup Whisper Dinner")
      expect(stored).not_to have_key("list_id")
    end

    it "is ONE row, so one sentence is one thing to see and one thing to cancel" do
      expect { schedule! }.to change(BuddyReminder, :count).by(1)
    end

    it "keeps the recurrence" do
      expect(schedule!.recurrence).to include("freq" => "daily", "at" => "21:00")
      expect(schedule!.fire_at.in_time_zone(user.timezone).strftime("%H:%M")).to eq("21:00")
    end

    it "takes a one-off time instead" do
      reminder = schedule!(repeat: nil, at: 3.hours.from_now.iso8601)

      expect(reminder.recurrence).to be_blank
      expect(reminder.action.length).to eq(3)
    end

    it "skips blank lines rather than filing an empty item" do
      expect(schedule!(items: "One\n\n  \nTwo").action.length).to eq(2)
    end

    it "stops on a date when they gave one" do
      expect(schedule!(until: 1.week.from_now.to_date.iso8601).recurrence).to include("until_on")
    end
  end

  # The list is looked up through add_list_item's OWN confirm, so a name that
  # matches nothing fails while they are still in the conversation rather than
  # silently at 9pm tomorrow.
  describe "what it refuses up front" do
    it "raises on a list that doesn't exist" do
      expect { schedule!(list: "Nonexistent") }.to raise_error(/no list matching/i)
    end

    it "raises on nothing to add" do
      expect { schedule!(items: "  \n \n") }.to raise_error(/nothing to add/i)
    end

    it "raises on a repeat spec it can't read" do
      expect { schedule!(repeat: "every so often") }.to raise_error(/unknown repeat spec/i)
    end

    it "raises rather than scheduling something into the past" do
      expect { schedule!(repeat: nil, at: 2.hours.ago.iso8601) }.to raise_error(/already passed/i)
    end
  end

  # The whole point: what happens at 9pm, with no model turn anywhere in it.
  describe "when it fires" do
    it "adds every item to the list" do
      reminder = schedule!
      reminder.update!(fire_at: 1.minute.ago)

      Buddy::ReminderFirer.fire!(reminder.reload)

      expect(list.reload.list_items.pluck(:name)).to contain_exactly(
        "Pickup Whisper Dinner", "Kitchen & Living 90% Reset", "Dish washer running/delay"
      )
    end

    it "rolls forward to the next night rather than firing once" do
      reminder = schedule!
      reminder.update!(fire_at: 1.minute.ago)

      expect { Buddy::ReminderFirer.fire!(reminder.reload) }
        .to(change { reminder.reload.fire_at })
      expect(reminder.reload.fire_at).to be > Time.current
    end
  end

  # A reminder carrying one call is the older shape and every existing row is
  # in it, so both have to keep working.
  describe "the single-call shape it did not replace" do
    it "still reads a lone hash" do
      reminder = BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "One thing.", fire_at: 1.hour.from_now,
        action: { "tool" => "add_list_item", "payload" => { "list_id" => list.id, "item" => "Milk" } }
      )

      expect(reminder.action_calls.length).to eq(1)
      expect(reminder.action_call[:tool_name]).to eq(:add_list_item)
    end

    it "drops a call naming a tool that no longer exists" do
      reminder = BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "Gone.", fire_at: 1.hour.from_now,
        action: [{ "tool" => "no_such_tool", "payload" => {} }]
      )

      expect(reminder.action_calls).to be_empty
    end
  end
end
