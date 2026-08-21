require "rails_helper"

# What a reminder DOES when it comes due. Most say something; some are an
# instruction and should carry it out instead of reading it back.
RSpec.describe Buddy::ReminderFirer do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::Jil).to receive(:trigger).and_return(true)
    user.update!(chore_household_id: household.id)
  }

  def remind!(text, **attrs)
    BuddyReminder.create!(
      { user: user, byte_conversation: convo, body: text, fire_at: 1.minute.from_now }.merge(attrs),
    )
  end

  def bodies
    convo.byte_messages.where(direction: :inbound).order(:id).pluck(:body)
  end

  # 21 Aug: Byte briefed once a minute for ten minutes until the reminder was
  # cancelled by hand. Agenda item 1006 ("Focus") started at 8:30, the briefing
  # is pulled 30 minutes ahead of the first thing, and 8:30 minus 30 is 8:00 -
  # exactly the time it had just fired at. Every roll-forward recomputed the
  # same past time, and a `fire_at` in the past is due on every tick.
  describe "the Today briefing rolling forward" do
    let(:zone)   { ActiveSupport::TimeZone[user.timezone.to_s] }
    let!(:agenda) { Agenda.create!(user: user, name: "Mine") }

    def briefing!(fire_at:)
      BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "Today briefing", fire_at: fire_at,
        recurrence: { "freq" => "daily", "at" => "08:30" }, metadata: { "today_briefing" => true },
      )
    end

    def event!(at)
      AgendaItem.create!(agenda: agenda, kind: :event, name: "Focus", all_day: false,
                         start_at: at, end_at: at + 1.hour)
    end

    it "lands tomorrow, not on a time that has already gone" do
      travel_to(zone.local(2026, 8, 21, 8, 0)) do
        event!(zone.local(2026, 8, 21, 8, 30))
        reminder = briefing!(fire_at: zone.local(2026, 8, 21, 8, 0))

        described_class.fire!(reminder)

        expect(reminder.reload.fire_at).to be > Time.current
        expect(reminder.fire_at.in_time_zone(zone).to_date).to eq(Date.new(2026, 8, 22))
      end
    end

    # The other half: rolling from `now` lands on today's own 8:30 slot, which
    # the briefing fired BEFORE. That's a second briefing the same morning.
    it "doesn't brief twice on the morning it fired early" do
      travel_to(zone.local(2026, 8, 21, 8, 0)) do
        event!(zone.local(2026, 8, 21, 8, 30))
        reminder = briefing!(fire_at: zone.local(2026, 8, 21, 8, 0))

        described_class.fire!(reminder)

        expect(reminder.reload.fire_at.in_time_zone(zone).to_date).not_to eq(Date.new(2026, 8, 21))
      end
    end

    it "still moves tomorrow's earlier when tomorrow starts early" do
      travel_to(zone.local(2026, 8, 21, 8, 0)) do
        event!(zone.local(2026, 8, 22, 7, 30))
        reminder = briefing!(fire_at: zone.local(2026, 8, 21, 8, 0))

        described_class.fire!(reminder)

        expect(reminder.reload.fire_at.in_time_zone(zone).strftime("%m-%d %H:%M")).to eq("08-22 07:00")
      end
    end

    it "leaves an ordinary recurring reminder alone" do
      travel_to(zone.local(2026, 8, 21, 8, 0)) do
        reminder = BuddyReminder.create!(
          user: user, byte_conversation: convo, body: "water the tomatoes",
          fire_at: zone.local(2026, 8, 21, 8, 0), recurrence: { "freq" => "daily", "at" => "08:30" },
        )

        described_class.fire!(reminder)

        expect(reminder.reload.fire_at.in_time_zone(zone).strftime("%m-%d %H:%M")).to eq("08-21 08:30")
      end
    end
  end

  describe "an ordinary reminder" do
    it "says it, with nothing stuck on the front" do
      described_class.fire!(remind!("take the trash out"))

      expect(bodies.last).to eq("Reminder: take the trash out")
    end

    # Someone with a day full of these reads the same character a dozen times
    # before they get to any of the words.
    it "pushes the words themselves, not a glyph and then the words" do
      described_class.fire!(remind!("take the trash out"))

      expect(WebPushNotifications).to have_received(:send_to_byte)
        .with(hash_including(title: "take the trash out"))
    end
  end

  # `kind` is picked once, by the model, and is invisible afterwards - so a
  # reminder meant to DO something arrives as a line of text and there's nowhere
  # to notice. This is decided when it fires instead.
  describe "a reminder that's really an instruction" do
    let!(:routine) {
      BuddyRoutine.create!(
        user:  user,
        name:  "wind down",
        steps: [BuddyRoutine.step(:log_event, { name: "Wind down" })],
      )
    }

    it "runs the routine it names rather than reading it out" do
      expect { described_class.fire!(remind!("run my wind down routine")) }
        .to change { ActionEvent.where(user_id: user.id).count }.by(1)

      expect(bodies).not_to include(a_string_starting_with("Reminder:"))
    end

    it "takes the other run-verbs people actually type" do
      %w[trigger fire start].each { |verb|
        expect { described_class.fire!(remind!("#{verb} wind down")) }
          .to change { ActionEvent.where(user_id: user.id).count }.by(1)
      }
    end

    it "fires a Jil task by name and says which one" do
      Task.create!(
        user: user, name: "Whisper Quiet", listener: "whisper-quiet",
        code: "", enabled: true, buddy_enabled: true
      )

      described_class.fire!(remind!("run Whisper Quiet"))

      expect(::Jil).to have_received(:trigger).with(user, :"whisper-quiet", {}, hash_including(auth: :buddy))
      expect(bodies.last).to include("Whisper Quiet")
    end

    # The narrow part, and the important one: a reminder is normally an
    # instruction to the PERSON, and those are imperative too.
    it "leaves an ordinary nudge alone even though it's phrased as an order" do
      described_class.fire!(remind!("take the trash out"))
      described_class.fire!(remind!("start the laundry"))

      expect(bodies).to all(start_with("Reminder:"))
    end

    # Resolved at fire time, so it degrades to a nudge instead of running
    # whatever is now closest to the name.
    it "goes back to being a nudge once the routine is gone" do
      routine.destroy!

      described_class.fire!(remind!("run my wind down routine"))

      expect(bodies.last).to eq("Reminder: run my wind down routine")
    end
  end

  describe "the recurring kind" do
    it "rolls forward instead of going terminal" do
      reminder = remind!("feed the fish", recurrence: { "kind" => "daily", "at" => "09:00" })

      described_class.fire!(reminder)

      expect(reminder.reload.fired_at).to be_nil
      expect(reminder.last_fired_at).to be_present
    end
  end
end
