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

  # `at` is the LATEST it may land, not a fixed hour. Moving the schedule onto a
  # reminder took it literally, and on 19 Aug all three briefings went out at
  # 08:30:40 — Rocco's landing in the same SECOND as an 08:30:00 Focus block.
  describe "an early start pulling the time forward" do
    def early_item(start_at, travel: nil)
      agenda = create(:agenda, user: user)
      create(
        :agenda_item, agenda: agenda, name: "Standup", start_at: start_at,
        metadata: travel ? { "travel" => { "travel_minutes" => travel } } : {},
      )
    end

    let(:tomorrow_at) { Buddy::Day.at(user, hour: 9, min: 0, now: 1.day.from_now) }

    it "briefs half an hour before departure, not at the flat hour" do
      early_item(tomorrow_at, travel: 25)

      fire = described_class.fire_time(user, tomorrow_at.change(hour: 8, min: 30))

      expect(fire).to eq(tomorrow_at - 55.minutes)
    end

    it "falls back to start minus the lead when no drive is known" do
      early_item(tomorrow_at)

      fire = described_class.fire_time(user, tomorrow_at.change(hour: 8, min: 30))

      expect(fire).to eq(tomorrow_at - 30.minutes)
    end

    # It only ever pulls FORWARD. A 9:30 start would compute to 9:00, which is
    # later than the hour they picked, and their hour wins.
    it "never pushes the briefing later than the hour they chose" do
      early_item(tomorrow_at.change(hour: 9, min: 30))
      at = tomorrow_at.change(hour: 8, min: 30)

      expect(described_class.fire_time(user, at)).to eq(at)
    end

    it "leaves a day with nothing early exactly where it was" do
      at = tomorrow_at.change(hour: 8, min: 30)

      expect(described_class.fire_time(user, at)).to eq(at)
    end

    it "ignores an event past the cutoff, however big the drive" do
      early_item(tomorrow_at.change(hour: 11, min: 0), travel: 90)
      at = tomorrow_at.change(hour: 8, min: 30)

      expect(described_class.fire_time(user, at)).to eq(at)
    end

    it "applies to the first occurrence a new schedule gets" do
      early_item(tomorrow_at, travel: 25)

      expect(described_class.ensure!(user).fire_at).to be < tomorrow_at.change(hour: 8, min: 30)
    end
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

    # The roll-forward is where tomorrow's time is decided, so the rule has to
    # be applied there and not only when the schedule is first made.
    it "puts tomorrow's early start on the slot it rolls to" do
      allow(Buddy::TodayBriefing).to receive(:deliver!).and_return(nil)
      reminder = described_class.ensure!(user)
      agenda = create(:agenda, user: user)
      early = Buddy::Day.at(user, hour: 9, min: 0, now: 1.day.from_now)
      create(
        :agenda_item, agenda: agenda, name: "Standup", start_at: early,
        metadata: { "travel" => { "travel_minutes" => 25 } },
      )

      Buddy::ReminderFirer.fire!(reminder)

      expect(reminder.reload.fire_at).to eq(early - 55.minutes)
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
