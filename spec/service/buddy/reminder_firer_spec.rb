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

  # The shape the Shower nudge is built out of: a rule about every occurrence of
  # a thing, a time that comes from the thing rather than from a clock, and a
  # state check so it stays quiet on a day it has already been done.
  #
  # The check looks for the DONE one and expects it to be absent, which is the
  # way round that works whether or not the occurrence exists as a row yet - a
  # repeat is a phantom until something touches it, and a phantom cannot be
  # found by a search.
  describe "a standing rule anchored to something that comes round" do
    let!(:agenda) { Agenda.create!(user: user, name: "Mine") }

    def shower!(completed: false)
      AgendaItem.create!(
        agenda: agenda, kind: :task, name: "Shower", start_at: 30.minutes.from_now,
        end_at: 45.minutes.from_now, completed_at: (Time.current if completed)
      )
    end

    def standing!
      Anchor.create!(user: user, key: "agenda:shower")
      AnchorFeeder.call(user)
      BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "Time to shower!", anchor: "agenda:shower",
        condition: { find: :agenda_items, query: 'name:"Shower" is:complete is:today', expect: :missing }
      )
    end

    around { |example| travel_to(Time.current.change(hour: 12, min: 0)) { example.run } }

    it "says it when the time comes and nothing has been ticked off" do
      shower!
      described_class.fire!(standing!)

      expect(bodies.join).to include("Reminder: Time to shower!")
    end

    # Nothing is posted and nothing is pushed; the chip is what explains the
    # silence without breaking it.
    it "stays quiet on a day it has already been done" do
      shower!(completed: true)
      described_class.fire!(standing!)

      expect(bodies.join).not_to include("Reminder: Time to shower!")
      expect(bodies.join).to include("Skipped")
    end

    # Going terminal here would retire the rule on its first firing, and nothing
    # would ever put it back.
    it "parks rather than finishing when there is no next one yet" do
      shower!
      reminder = standing!

      travel 31.minutes
      described_class.fire!(reminder)

      expect(reminder.reload.fire_at).to be_nil
      expect(reminder.fired_at).to be_nil
      expect(BuddyReminder.pending).to include(reminder)
    end
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

  # The morning routine ran its whole scene twice on two mornings in three. The
  # HASS call inside it hangs for a 60s timeout, which is longer than the gap
  # between sweeps, and for that whole minute `fire_at` still read as due.
  describe "while the dispatch is still running" do
    let!(:task) {
      Task.create!(user: user, name: "Good Morning", listener: "good-morning",
                   code: "", enabled: true, buddy_enabled: true)
    }

    it "has already rolled forward, so the next sweep finds nothing due" do
      reminder = remind!("run Good Morning", recurrence: { "kind" => "daily", "at" => "05:45" })
      due_mid_dispatch = nil
      allow(::Jil).to receive(:trigger) {
        due_mid_dispatch = BuddyReminder.find(reminder.id).fire_at <= Time.current
        true
      }

      described_class.fire!(reminder)

      expect(due_mid_dispatch).to be(false)
    end

    # The cost of rolling first, stated so it stays deliberate: a dispatch that
    # blows up has already moved the row. It is reported rather than retried.
    it "reports a dispatch that raises instead of leaving the row due" do
      reminder = remind!("run Good Morning", recurrence: { "kind" => "daily", "at" => "05:45" })
      allow(::Jil).to receive(:trigger).and_raise(Net::ReadTimeout)
      allow(Buddy::Errors).to receive(:report)

      described_class.fire!(reminder)

      expect(Buddy::Errors).to have_received(:report).with(hash_including(section: "reminder_firer.fire"))
      expect(reminder.reload.fire_at).to be > Time.current
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
