require "rails_helper"

RSpec.describe BuddyReminderSweepWorker do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:old)   { (described_class::RETENTION + 1.day).ago }

  def reminder!(**attrs)
    BuddyReminder.create!(
      { user: user, byte_conversation: convo, body: "x", fire_at: 1.hour.from_now }.merge(attrs),
    )
  end

  def watch!(**attrs)
    BuddyWatch.create!(
      {
        user:              user,
        byte_conversation: convo,
        kind:              "prompt",
        body:              "x",
        trigger_scope:     "item",
        listener:          "item",
        one_shot:          false,
      }.merge(attrs),
    )
  end

  # A watch can be open-ended ("each time the doorbell sees somebody today"),
  # so expiry is the only thing that retires one.
  it "deletes fired, cancelled and expired rows once past the grace period" do
    gone = [
      reminder!(fired_at: old),
      reminder!(cancelled_at: old),
      watch!(expires_at: old),
      watch!(one_shot: true, fired_at: old),
      watch!(cancelled_at: old),
    ]

    described_class.new.perform

    gone.each { |row| expect(row.class.exists?(row.id)).to be(false), row.inspect }
  end

  # A reminder that fired this morning is still worth scrolling back to, and a
  # watch someone let lapse is worth a glance before it goes. A repeat never
  # sets fired_at, so age alone must never retire one.
  it "keeps recent, still-waiting, standing and recurring rows" do
    kept = [
      reminder!(fired_at: 1.hour.ago),
      watch!(expires_at: 1.hour.ago),
      reminder!(fire_at: 2.hours.from_now),
      watch!(created_at: 2.years.ago),
      reminder!(recurrence: { "freq" => "daily", "at" => "09:00" }, created_at: 2.years.ago),
    ]

    described_class.new.perform

    kept.each { |row| expect(row.class.exists?(row.id)).to be(true), row.inspect }
  end

  # `pending` is "not fired, not cancelled", and a repeat never sets fired_at -
  # so one whose end date has passed stays in the live list forever with
  # nothing left to fire.
  describe "a repeat that has run out" do
    it "stamps it so it drops out of the live list, leaving one with occurrences to come" do
      done = reminder!(recurrence: { "freq" => "daily", "at" => "09:00", "until_on" => 2.days.ago.to_date.iso8601 })
      live = reminder!(recurrence: { "freq" => "daily", "at" => "09:00", "until_on" => 30.days.from_now.to_date.iso8601 })

      described_class.new.perform

      expect(done.reload.fired_at).to be_present
      expect(BuddyReminder.pending).not_to include(done)
      expect(live.reload.fired_at).to be_nil
    end
  end

  it "is safe to run twice" do
    reminder!(fired_at: old)
    watch!(expires_at: old)

    described_class.new.perform
    counts = [BuddyReminder.count, BuddyWatch.count]

    expect { described_class.new.perform }.not_to raise_error
    expect([BuddyReminder.count, BuddyWatch.count]).to eq(counts)
  end
end
