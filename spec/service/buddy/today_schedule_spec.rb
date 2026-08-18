require "rails_helper"

# When the morning briefing goes out, and whether it goes out at all.
#
# It used to be a hardcoded 8:30 inside Buddy::TodayScheduler on an every-minute
# cron. It's a recurring BuddyReminder now, carrying the `today_briefing` tool
# as its action - so `move_reminder` changes the hour and `cancel_reminder`
# stops it, both of which already existed.
RSpec.describe Buddy::TodaySchedule do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    # deliver! kicks a real turn; the seed row is all these care about.
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  describe ".ensure!" do
    it "makes a daily reminder that fires the briefing" do
      reminder = described_class.ensure!(user)

      expect(reminder.recurrence).to include("freq" => "daily", "at" => "08:30")
      expect(reminder.action_call).to eq(tool_name: :today_briefing, payload: {})
    end

    it "puts the first fire in the future" do
      expect(described_class.ensure!(user).fire_at).to be > Time.current
    end

    it "takes an hour when given one" do
      expect(described_class.ensure!(user, at: "06:15").recurrence["at"]).to eq("06:15")
    end

    it "makes one, however many times it's called" do
      3.times { described_class.ensure!(user) }

      expect(BuddyReminder.where(user: user).count).to eq(1)
    end

    # Their own thread, never the wall tablet — decided once, here, rather than
    # at every fire.
    it "brief them where they read, not on the kiosk" do
      kiosk = user.byte_conversations.create!(
        mode: :buddy, name: "Kitchen", last_message_at: Time.current, metadata: { "kiosk" => true },
      )

      expect(described_class.ensure!(user).byte_conversation).not_to eq(kiosk)
    end

    # "I don't want this any more" has to survive the next time anything calls
    # this, or cancelling is a thing that undoes itself overnight.
    it "does not put back one they cancelled" do
      described_class.ensure!(user).update!(cancelled_at: Time.current)

      described_class.ensure!(user)

      expect(BuddyReminder.pending.where(user: user)).to be_empty
      expect(described_class).not_to be_scheduled(user)
    end
  end

  # The reminder's body normally becomes the heading over whatever it runs.
  # Above a briefing that opens with its own greeting, that lands on the line
  # the briefing's prompt works hardest to get right.
  describe "firing it" do
    it "posts no heading above the briefing" do
      allow(Buddy::TodayBriefing).to receive(:deliver!).and_return(nil)
      reminder = described_class.ensure!(user)

      Buddy::ReminderFirer.fire!(reminder)

      expect(convo.byte_messages.where("body LIKE '%Today briefing%'")).to be_empty
    end

    it "delivers the briefing into their own thread" do
      allow(Buddy::TodayBriefing).to receive(:deliver!).and_return(nil)

      Buddy::ReminderFirer.fire!(described_class.ensure!(user))

      expect(Buddy::TodayBriefing).to have_received(:deliver!).with(user, convo, scheduled: true)
    end

    # A daily reminder never goes terminal: it stamps last_fired_at, rolls
    # fire_at to the next occurrence, and stays pending forever.
    it "stays pending with tomorrow's slot on it" do
      allow(Buddy::TodayBriefing).to receive(:deliver!).and_return(nil)
      reminder = described_class.ensure!(user)

      Buddy::ReminderFirer.fire!(reminder)

      expect(reminder.reload.fired_at).to be_nil
      expect(reminder.last_fired_at).to be_present
      expect(reminder.fire_at).to be > Time.current
      expect(described_class).to be_scheduled(user)
    end

    # An ordinary action reminder still says what it's running — only a tool
    # that posts its own message goes quiet.
    it "still heads an ordinary scheduled call" do
      other = BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "Water the plants",
        fire_at: 1.minute.ago, action: { "tool" => "log_event", "payload" => { "name" => "Water" } }
      )

      Buddy::ReminderFirer.fire!(other)

      expect(convo.byte_messages.where("body LIKE '%Water the plants%'")).to be_present
    end
  end

  # The guard used to sit in Buddy::TodayScheduler. Buddy::ReminderFirer has
  # never checked it, so moving the schedule onto a reminder would have dropped
  # it silently — a briefing arriving at 3am because nothing on the new path
  # knew to ask.
  describe "while Buddy is asleep" do
    before { allow(Buddy::SleepGuard).to receive(:sleeping?).with(user).and_return(true) }

    it "sends no scheduled briefing" do
      expect(Buddy::TodayBriefing.deliver!(user, convo, scheduled: true)).to be_nil
    end

    # Someone asking for one at 2am has already answered the question the guard
    # exists to ask.
    it "still sends one they asked for by hand" do
      expect(Buddy::TodayBriefing.deliver!(user, convo, scheduled: false)).to be_present
    end
  end
end
