require "rails_helper"

RSpec.describe ChoreSerializer, "marked_due_at" do
  let(:user) { create(:user) }
  let(:day) { ChoreDay.current(user) }
  # show_on_daily_view: :never so we know any Today appearance is
  # solely from the mark — schedule contribution is ruled out.
  let(:chore) {
    create(
      :chore,
      created_by_user:    user,
      show_on_daily_view: :never,
      recurrence:         { freq: :never },
    )
  }

  def serialize(c, viewer: user)
    described_class.new(c, viewer: viewer).as_json
  end

  describe "today_visible?" do
    it "is false without a stamp (schedule-never chore)" do
      expect(serialize(chore)[:today_visible]).to be(false)
    end

    it "is true when stamped this chore-day" do
      chore.update!(marked_due_at: Time.current)
      expect(serialize(chore)[:today_visible]).to be(true)
    end

    it "is true when stamped on a previous chore-day (carryover)" do
      chore.update!(marked_due_at: ChoreDay.starts_at(day, user) - 1.day)
      expect(serialize(chore)[:today_visible]).to be(true)
    end

    it "is FALSE when stamped on a future chore-day (not yet due)" do
      chore.update!(marked_due_at: ChoreDay.starts_at(day + 1, user))
      json = serialize(chore)
      expect(json[:today_visible]).to be(false)
      expect(json[:due_today]).to be(false)
    end

    it "stays hidden when archived even with a stamp" do
      chore.update!(marked_due_at: Time.current, archived_at: Time.current)
      expect(serialize(chore)[:today_visible]).to be(false)
    end

    it "stays hidden for a non-assignee on an assigned household chore" do
      other = create(:user, chore_household: user.chore_household)
      chore.update!(sharing_mode: :household, assigned_to_user_id: other.id, marked_due_at: Time.current)
      expect(serialize(chore, viewer: user)[:today_visible]).to be(false)
      expect(serialize(chore, viewer: other)[:today_visible]).to be(true)
    end
  end

  describe "due_today?" do
    it "is true when stamped at-or-after the chore-day boundary (this chore-day)" do
      chore.update!(marked_due_at: ChoreDay.starts_at(day, user))
      expect(serialize(chore)[:due_today]).to be(true)
    end

    it "is false (→ Scheduled/overdue section) when stamped on a prior chore-day" do
      chore.update!(marked_due_at: ChoreDay.starts_at(day, user) - 1.second)
      json = serialize(chore)
      expect(json[:today_visible]).to be(true)
      expect(json[:due_today]).to be(false)
    end
  end

  describe "JSON payload" do
    it "emits marked_due_on as the viewer's chore-day date (YYYY-MM-DD)" do
      chore.update!(marked_due_at: ChoreDay.starts_at(day, user) + 6.hours)
      expect(serialize(chore)[:marked_due_on]).to eq(day.iso8601)
    end

    it "emits marked_due_on for prior chore-day stamps too" do
      chore.update!(marked_due_at: ChoreDay.starts_at(day - 3, user) + 5.hours)
      expect(serialize(chore)[:marked_due_on]).to eq((day - 3).iso8601)
    end

    it "emits marked_due_at as ISO-8601 (ms) when set" do
      t = Time.current
      chore.update!(marked_due_at: t)
      expect(serialize(chore)[:marked_due_at]).to eq(t.iso8601(3))
    end

    it "emits nil when unset" do
      expect(serialize(chore)[:marked_due_at]).to be_nil
    end
  end
end
