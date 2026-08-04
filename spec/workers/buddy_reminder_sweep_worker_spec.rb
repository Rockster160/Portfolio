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
        match:             {},
        one_shot:          false,
      }.merge(attrs),
    )
  end

  describe "what it clears" do
    it "deletes a one-shot reminder that fired long enough ago" do
      gone = reminder!(fired_at: old)

      described_class.new.perform

      expect(BuddyReminder.exists?(gone.id)).to be(false)
    end

    it "deletes a cancelled reminder" do
      gone = reminder!(cancelled_at: old)

      described_class.new.perform

      expect(BuddyReminder.exists?(gone.id)).to be(false)
    end

    # The whole reason this worker exists. "Let me know each time the doorbell
    # sees somebody today" had nothing that would ever retire it.
    it "deletes a watch whose expiry has passed" do
      gone = watch!(expires_at: old)

      described_class.new.perform

      expect(BuddyWatch.exists?(gone.id)).to be(false)
    end

    it "deletes a one-shot watch that already fired" do
      gone = watch!(one_shot: true, fired_at: old)

      described_class.new.perform

      expect(BuddyWatch.exists?(gone.id)).to be(false)
    end

    it "deletes a cancelled watch" do
      gone = watch!(cancelled_at: old)

      described_class.new.perform

      expect(BuddyWatch.exists?(gone.id)).to be(false)
    end
  end

  # A reminder that fired this morning is still worth scrolling back to, and a
  # watch someone let lapse is worth a glance before it goes.
  describe "the grace period" do
    it "keeps one that only just fired" do
      recent = reminder!(fired_at: 1.hour.ago)

      described_class.new.perform

      expect(BuddyReminder.exists?(recent.id)).to be(true)
    end

    it "keeps a watch that only just expired" do
      recent = watch!(expires_at: 1.hour.ago)

      described_class.new.perform

      expect(BuddyWatch.exists?(recent.id)).to be(true)
    end
  end

  describe "what it leaves alone" do
    it "keeps a reminder still waiting to fire" do
      live = reminder!(fire_at: 2.hours.from_now)

      described_class.new.perform

      expect(BuddyReminder.exists?(live.id)).to be(true)
    end

    it "keeps a standing watch with no expiry, however old" do
      live = watch!(created_at: 2.years.ago)

      described_class.new.perform

      expect(BuddyWatch.exists?(live.id)).to be(true)
    end

    # A repeat never sets fired_at, so age alone must never retire one.
    it "keeps a recurring reminder that's been running for years" do
      live = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" }, created_at: 2.years.ago)

      described_class.new.perform

      expect(BuddyReminder.exists?(live.id)).to be(true)
    end
  end

  # `pending` is "not fired, not cancelled", and a repeat never sets fired_at -
  # so one whose end date has passed stays in the live list forever with
  # nothing left to fire.
  describe "a repeat that has run out" do
    it "stamps it so it drops out of the live list" do
      done = reminder!(recurrence: { "freq" => "daily", "at" => "09:00", "until_on" => 2.days.ago.to_date.iso8601 })

      described_class.new.perform

      expect(done.reload.fired_at).to be_present
      expect(BuddyReminder.pending).not_to include(done)
    end

    it "leaves one with occurrences still to come" do
      live = reminder!(recurrence: { "freq" => "daily", "at" => "09:00", "until_on" => 30.days.from_now.to_date.iso8601 })

      described_class.new.perform

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
