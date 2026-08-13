require "rails_helper"

# "Charge village car if the chore isn't done yet", set as three separate
# reminders an hour apart. Both halves of that were wrong and neither was
# visible from the row: the "if" was decorative, and three rows can't be
# cancelled, edited or satisfied together.
#
# This covers what a reminder does with a condition at fire time, and the
# intraday window that makes three rows one.
RSpec.describe "Buddy conditional reminders" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let!(:chore) {
    create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Car")
  }
  let(:tz) { ActiveSupport::TimeZone["America/Denver"] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::WebPushNotifications).to receive(:update_count)
    user.update!(chore_household_id: household.id)
  end

  def condition(over = {})
    { "find" => "chore_completions", "query" => "name:\"Charge Villager Car\" is:today", "expect" => "missing" }.merge(over)
  end

  def reminder!(**attrs)
    BuddyReminder.create!(
      user: user, byte_conversation: convo, body: "Charge the village car",
      fire_at: 1.minute.ago, **attrs
    )
  end

  # Real replies only. A skip files a `buddy_activity` receipt, which is
  # deliberately not a message — it explains a silence without breaking it.
  def said
    convo.byte_messages.where(direction: :inbound).reject { |m| m.metadata["kind"] == "buddy_activity" }.map(&:body)
  end

  def completed!(at: Time.current)
    ChoreCompletion.create!(chore: chore, user: user, completed_at: at, day_key: ChoreDay.current(user, at: at))
  end

  describe "a condition at fire time" do
    it "delivers while the chore is still outstanding" do
      Buddy::ReminderFirer.fire!(reminder!(condition: condition))

      expect(said.join).to include("Charge the village car")
    end

    it "says nothing once the chore is done" do
      completed!

      Buddy::ReminderFirer.fire!(reminder!(condition: condition))

      expect(said).to be_empty
    end

    # Skipping is not the same as never being due. The row still moves, so it
    # leaves `pending` and shows up in context as something that came and went,
    # rather than vanishing and leaving "did that go off?" unanswerable.
    it "still records that a skipped one came due" do
      completed!
      rem = reminder!(condition: condition)

      Buddy::ReminderFirer.fire!(rem)

      expect(rem.reload.fired_at).to be_present
      expect(rem.metadata["last_skipped_at"]).to be_present
    end

    # A skip is invisible by design, and invisible is exactly how a condition
    # that's quietly wrong stays wrong. The pill says what was checked.
    #
    # A chip and not a message: `buddy_activity` is dropped by both the unread
    # count and the push path, so this explains a silence without breaking it.
    it "leaves a receipt saying what it checked" do
      completed!

      Buddy::ReminderFirer.fire!(reminder!(condition: condition))

      chip = convo.byte_messages.where(direction: :inbound).last
      expect(chip.metadata["kind"]).to eq("buddy_activity")
      expect(chip.metadata["ok"]).to be(false)
      expect(chip.body).to include("Skipped")
      expect(chip.metadata["detail"]).to include("no chore completions")
    end

    it "leaves no receipt when it actually delivered" do
      Buddy::ReminderFirer.fire!(reminder!(condition: condition))

      kinds = convo.byte_messages.where(direction: :inbound).map { |m| m.metadata["kind"] }
      expect(kinds).not_to include("buddy_activity")
    end

    it "leaves a delivered one unmarked as skipped" do
      rem = reminder!(condition: condition)

      Buddy::ReminderFirer.fire!(rem)

      expect(rem.reload.metadata["last_skipped_at"]).to be_nil
    end

    it "carries on exactly as before when there's no condition" do
      Buddy::ReminderFirer.fire!(reminder!)

      expect(said.join).to include("Charge the village car")
    end

    # Skipping tonight is not skipping every night.
    it "rolls a recurring one forward rather than ending it" do
      completed!
      rem = reminder!(condition: condition, recurrence: { "freq" => "daily", "at" => "21:00" })

      Buddy::ReminderFirer.fire!(rem)

      expect(rem.reload.fired_at).to be_nil
      expect(rem.fire_at).to be > Time.current
    end

    # Both outcomes are wrong and they are not equally wrong: a nudge that
    # arrives when it needn't is noise, and one that silently vanishes is the
    # thing they asked to be told about, gone, with nothing to say it was due.
    it "delivers anyway when the condition can't be evaluated" do
      allow(Buddy::Errors).to receive(:report)

      Buddy::ReminderFirer.fire!(reminder!(condition: condition("find" => "nonsense")))

      expect(said.join).to include("Charge the village car")
      expect(Buddy::Errors).to have_received(:report)
    end

    # The condition gates the whole fire path, not just the text one.
    it "holds back a reminder that would have RUN something" do
      routine = BuddyRoutine.create!(
        user: user, name: "car charge",
        steps: [BuddyRoutine.step(:mac_command, { command: "dark_monitors" })],
      )
      completed!

      Buddy::ReminderFirer.fire!(reminder!(body: "run car charge", condition: condition))

      expect(routine.reload.run_count).to eq(0)
    end
  end

  # Recurrence is date-only and shared with the calendar (plus a JS port with a
  # parity spec), so the sub-daily half lives on the reminder: Recurrence still
  # says WHICH DAYS, this says which times within them.
  describe "repeating within a day" do
    def hourly_window
      { "freq" => "daily", "at" => "21:00", "until_at" => "23:00", "every_minutes" => 60 }
    end

    # `created_at` is where a recurrence counts from when the rule names no
    # start of its own, and a reminder can't fire before it was set. Every
    # assertion below names particular dates, so it has to be pinned - left to
    # default these passed on the day they were written and failed the next
    # morning, when "2026-08-12" stopped being today.
    def dated!(**attrs)
      reminder!(created_at: tz.parse("2026-08-12 08:00"), **attrs)
    end

    it "walks 9, 10, 11 and then stops for the night" do
      rem = dated!(recurrence: hourly_window)

      fires = []
      at = tz.parse("2026-08-12 20:00")
      4.times do
        at = rem.next_fire_at(from: at)
        fires << at.in_time_zone(tz).strftime("%-m/%-d %-I:%M %p")
      end

      expect(fires).to eq(["8/12 9:00 PM", "8/12 10:00 PM", "8/12 11:00 PM", "8/13 9:00 PM"])
    end

    it "is one row, so cancelling it cancels all of tonight" do
      rem = dated!(recurrence: hourly_window)

      expect(rem.intraday?).to be(true)
      expect(BuddyReminder.where(user_id: user.id).count).to eq(1)
    end

    it "leaves an ordinary daily reminder firing once" do
      rem = dated!(recurrence: { "freq" => "daily", "at" => "21:00" })

      first  = rem.next_fire_at(from: tz.parse("2026-08-12 20:00"))
      second = rem.next_fire_at(from: first)

      expect(second.to_date).to eq(first.to_date + 1)
      expect(rem.intraday?).to be(false)
    end

    # A step of zero never advances, and this runs inside the every-minute
    # sweep. Floored rather than rejected so a bad rule still terminates.
    it "refuses to build a window that never advances" do
      rem = dated!(recurrence: hourly_window.merge("every_minutes" => 0))

      expect(rem.slots_on(tz.parse("2026-08-12").to_date, tz).length).to be <= BuddyReminder::MAX_INTRADAY_SLOTS
    end

    it "combines with the day pattern rather than replacing it" do
      rem = dated!(recurrence: hourly_window.merge("freq" => "weekly", "by_day" => ["sat"]))

      first = rem.next_fire_at(from: tz.parse("2026-08-12 20:00")) # a Wednesday
      expect(first.in_time_zone(tz).strftime("%A %-I:%M %p")).to eq("Saturday 9:00 PM")

      second = rem.next_fire_at(from: first)
      expect(second.in_time_zone(tz).strftime("%A %-I:%M %p")).to eq("Saturday 10:00 PM")
    end

    # The other half of "three reminders should have been one": an end date, so
    # tonight's window doesn't come back tomorrow.
    it "stops for good at the until date" do
      rem = dated!(recurrence: hourly_window.merge("until_on" => "2026-08-12"))

      last = rem.next_fire_at(from: tz.parse("2026-08-12 22:30"))
      expect(last.in_time_zone(tz).hour).to eq(23)
      expect(rem.next_fire_at(from: last)).to be_nil
    end
  end
end
