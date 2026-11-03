# == Schema Information
#
# Table name: buddy_reminders
#
#  id                   :bigint           not null, primary key
#  user_id              :bigint           not null
#  byte_conversation_id :bigint           not null
#  kind                 :string           default("reminder"), not null
#  body                 :text             not null
#  fire_at              :datetime         not null
#  fired_at             :datetime
#  cancelled_at         :datetime
#  metadata             :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  recurrence           :jsonb
#  last_fired_at        :datetime
#  notify_user_id       :bigint
#
require "rails_helper"

RSpec.describe BuddyReminder do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:zone)  { ActiveSupport::TimeZone[user.timezone] }

  # `created_at` is where an interval counts FROM when the rule doesn't name a
  # start of its own, so it has to be pinned for a spec that asserts on
  # particular dates - a reminder can't fire before it was set.
  def reminder(recurrence, body: "Grab my Loops")
    described_class.create!(
      user: user, byte_conversation: convo, body: body,
      fire_at: zone.local(2026, 1, 1, 9, 0), recurrence: recurrence,
      created_at: zone.local(2026, 1, 1, 9, 0)
    )
  end

  # Reminders share the calendar's Recurrence: interval, nth-weekday, end dates
  # and excluded dates all apply.
  describe "#next_fire_at" do
    def next_after(recurrence, from)
      reminder(recurrence).next_fire_at(from: zone.parse(from))
    end

    it "finds the next fire across the shared recurrence vocabulary", :aggregate_failures do
      [
        # Daily, rolled forward once its hour has gone by, and kept while ahead.
        [{ freq: :daily, at: "09:00" }, "2026-03-04 09:01", "2026-03-05 09:00"],
        [{ freq: :daily, at: "09:00" }, "2026-03-04 08:59", "2026-03-04 09:00"],
        # Friday the 6th skips the weekend.
        [{ freq: :weekdays, at: "07:54" }, "2026-03-06 08:00", "2026-03-09 07:54"],
        [{ freq: :weekly, by_day: %w[mon wed], at: "18:00" }, "2026-03-04 19:00", "2026-03-09 18:00"],
        [{ freq: :monthly, by_set_pos: 2, by_day: %w[tue], at: "10:00" }, "2026-03-01 00:00", "2026-03-10 10:00"],
        [{ freq: :monthly, by_set_pos: -1, by_day: %w[fri], at: "17:00" }, "2026-03-01 00:00", "2026-03-27 17:00"],
        # Every other Tuesday, counting from where it started.
        [
          { freq: :custom, interval: 2, unit: :week, at: "10:00", starts_on: "2026-03-03" },
          "2026-03-04 00:00",
          "2026-03-17 10:00",
        ],
        [{ freq: :daily, at: "09:00", excluded_dates: ["2026-03-05"] }, "2026-03-04 10:00", "2026-03-06 09:00"],
        [{ freq: :daily, at: "09:00", until_on: "2026-03-05" }, "2026-03-06 00:00", nil],
      ].each do |rule, from, want|
        got = next_after(rule, from)&.strftime("%Y-%m-%d %H:%M")
        expect(got).to eq(want), "#{rule.inspect} from #{from}"
      end
    end

    it "is nil for a one-off" do
      expect(reminder(nil).next_fire_at).to be_nil
    end
  end

  # A row written by the previous release has to keep firing through the
  # deploy, so the old vocabulary is translated on READ rather than only by the
  # migration that cleans it up.
  describe "the shape reminders used to store" do
    it "reads every old frequency", :aggregate_failures do
      [
        [{ kind: "daily", at: "21:30" }, "2026-03-04 22:00", "2026-03-05 21:30"],
        [{ kind: "weekdays", at: "07:54" }, "2026-03-06 08:00", "2026-03-09 07:54"],
        [{ kind: "weekly", weekday: "wednesday", at: "20:00" }, "2026-03-04 21:00", "2026-03-11 20:00"],
        [{ kind: "monthly", day: 15, at: "09:00" }, "2026-03-16 00:00", "2026-04-15 09:00"],
      ].each do |rule, from, want|
        got = reminder(rule).next_fire_at(from: zone.parse(from)).strftime("%Y-%m-%d %H:%M")
        expect(got).to eq(want), rule.inspect
      end
    end

    it "translates it into the shared vocabulary" do
      converted = reminder({ kind: "weekly", weekday: "wednesday", at: "20:00" }).normalized_recurrence

      expect(converted).to include("freq" => "weekly", "by_day" => ["wed"], "at" => "20:00")
    end
  end

  # Asking again about something you already asked about is the normal shape of
  # a conversation, and Buddy has no memory of having set one that morning.
  describe ".clashing" do
    let(:noon) { zone.local(2026, 1, 1, 12, 0) }

    def one_off!(body, at: noon)
      described_class.create!(user: user, byte_conversation: convo, body: body, fire_at: at)
    end

    def daily!(body, at: noon)
      described_class.create!(
        user: user, byte_conversation: convo, body: body, fire_at: at,
        recurrence: { "freq" => "daily", "at" => "12:00", "starts_on" => "2026-01-01" },
      )
    end

    it "finds the same thing already set for the same minute" do
      existing = one_off!("Take the trash out")

      expect(described_class.clashing(user, "take the trash out", noon)).to eq(existing)
    end

    # Same minute alone would collapse two genuinely different reminders, and
    # losing a real one is worse than the double ping this exists to stop.
    it "leaves a different thing at the same minute alone" do
      one_off!("Take the trash out")

      expect(described_class.clashing(user, "call mom", noon)).to be_nil
    end

    it "leaves the same thing at a different minute alone" do
      one_off!("Take the trash out")

      expect(described_class.clashing(user, "take the trash out", noon + 1.hour)).to be_nil
    end

    # The minute window is what keeps a recurring one from matching on days it
    # isn't about to fire, so recurring reminders are compared like any other.
    it "catches a RECURRING one whose next fire is that minute" do
      existing = daily!("Check the bamboo tree and water all the plants.")

      expect(described_class.clashing(user, "Ping me when it's time to do the plant check.", noon))
        .to eq(existing)
    end

    it "still leaves a recurring one alone on a day it isn't about to fire" do
      daily!("Check the bamboo tree and water all the plants.")

      expect(described_class.clashing(user, "water the plants", noon + 1.day)).to be_nil
    end

    # Plural-vs-singular is how the same subject usually turns up twice, and
    # "plants" against "plant" shared no word at all.
    it "matches across a plural" do
      existing = one_off!("Water the plants")

      expect(described_class.clashing(user, "do the plant check", noon)).to eq(existing)
    end

    it "leaves short words unstemmed, so gas isn't ga" do
      one_off!("Get gas")

      expect(described_class.clashing(user, "check the ga meter", noon)).to be_nil
    end

    it "ignores one that already fired" do
      one_off!("Take the trash out").update!(fired_at: Time.current)

      expect(described_class.clashing(user, "take the trash out", noon)).to be_nil
    end

    it "ignores somebody else's" do
      other = create(:user)
      other_convo = other.byte_conversations.create!(mode: :buddy, name: "Buddy")
      described_class.create!(user: other, byte_conversation: other_convo, body: "Take the trash out", fire_at: noon)

      expect(described_class.clashing(user, "take the trash out", noon)).to be_nil
    end
  end
end
