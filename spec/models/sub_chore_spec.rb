require "rails_helper"

RSpec.describe "SubChore behavior" do
  let(:user) { create(:user) }
  let(:parent) { create(:chore, created_by_user: user, name: "Projects", reward_pebbles: 5, one_off: false) }

  describe "validations" do
    it "allows one_off=false on sub-chores (recurring sub-checklist item)" do
      sub = build(:chore, created_by_user: user, parent_chore: parent, one_off: false)
      expect(sub).to be_valid
    end

    it "rejects a parent that is itself a sub-chore (no chains)" do
      grandparent = create(:chore, created_by_user: user, one_off: false)
      first_sub = create(:chore, created_by_user: user, parent_chore: grandparent, one_off: true)
      second = build(:chore, created_by_user: user, parent_chore: first_sub, one_off: true)
      expect(second).not_to be_valid
      expect(second.errors[:parent_chore_id]).to include(/cannot itself be a sub-chore/)
    end

    it "rejects a one-off parent (parent must be persistent)" do
      one_off_parent = create(:chore, created_by_user: user, one_off: true)
      sub = build(:chore, created_by_user: user, parent_chore: one_off_parent, one_off: true)
      expect(sub).not_to be_valid
      expect(sub.errors[:parent_chore_id]).to include(/one-off/)
    end

    it "rejects a parent in a different household" do
      other_user = create(:user)
      foreign_parent = create(:chore, created_by_user: other_user, one_off: false)
      sub = build(:chore, created_by_user: user, parent_chore: foreign_parent, one_off: true)
      expect(sub).not_to be_valid
      expect(sub.errors[:parent_chore_id]).to include(/same household/)
    end
  end

  describe "cascade archive" do
    it "archives live sub-chores when the parent is archived" do
      sub_a = create(:chore, created_by_user: user, parent_chore: parent, one_off: true)
      sub_b = create(:chore, created_by_user: user, parent_chore: parent, one_off: true)
      parent.update!(archived_at: Time.current)
      expect(sub_a.reload.archived_at).to be_present
      expect(sub_b.reload.archived_at).to be_present
    end
  end

  describe ChoreCompleter, "with sub-chores" do
    let(:sub) { create(:chore, created_by_user: user, parent_chore: parent, one_off: true, reward_pebbles: 3, icon: "🛠️") }

    it "credits the parent and stamps sub_chore_id" do
      result = described_class.new(sub, user).call
      completion = result.completion
      expect(completion.chore_id).to eq(parent.id)
      expect(completion.sub_chore_id).to eq(sub.id)
      expect(completion.paid_pebbles).to eq(3) # sub's reward, not parent's
    end

    it "bubbles up the sub-chore's own hot multiplier into the parent-credited completion" do
      create(:chore_hot_pick, chore: sub, multiplier: 3.0, day_key: ChoreDay.current(user))
      result = described_class.new(sub, user).call
      expect(result.completion.hot_multiplier).to eq(3.0)
      expect(result.completion.paid_pebbles).to eq(9) # 3 * 3.0
      expect(result.completion.metadata["hot_pick"]).to eq(true)
    end

    it "falls back to the parent's hot pick if the sub-chore isn't a hot pick" do
      create(:chore_hot_pick, chore: parent, multiplier: 2.0, day_key: ChoreDay.current(user))
      result = described_class.new(sub, user).call
      expect(result.completion.hot_multiplier).to eq(2.0)
      expect(result.completion.paid_pebbles).to eq(6) # sub.reward (3) * parent's 2.0
    end

    it "uses the PARENT's cooldown — a sub tap inside the cooldown window skips payout" do
      parent.update!(threshold_seconds: 6 * 3600)
      base = Time.current
      sub_a = create(:chore, created_by_user: user, parent_chore: parent, one_off: true, reward_pebbles: 3)
      sub_b = create(:chore, created_by_user: user, parent_chore: parent, one_off: true, reward_pebbles: 3)
      travel_to(base) { described_class.new(sub_a, user).call }
      travel_to(base + 3.hours) {
        result = described_class.new(sub_b, user).call
        expect(result).to be_skipped
      }
    end

    it "advances the PARENT's streak, not a sub-chore-specific one" do
      described_class.new(sub, user).call
      expect(ChoreStreak.find_by(user: user, chore: parent)&.current_streak).to eq(1)
      expect(ChoreStreak.find_by(user: user, chore: sub)).to be_nil
    end

    it "keeps marked_due intact on completion (cleared at next-day rollover instead)" do
      parent.update!(marked_due_at: 1.day.ago)
      sub.update!(marked_due_at: 1.day.ago)
      described_class.new(sub, user).call
      # Sync clear would break the lock-at-4am contract on Today; the
      # ChoreDailyResetWorker handles cleanup.
      expect(parent.reload.marked_due_at).to be_present
      expect(sub.reload.marked_due_at).to be_present
    end
  end

  describe ChoreSerializer, "for sub-chores" do
    let(:sub) { create(:chore, created_by_user: user, parent_chore: parent, one_off: true, reward_pebbles: 3) }

    it "done_count_today is keyed by sub_chore_id, not chore_id" do
      sibling = create(:chore, created_by_user: user, parent_chore: parent, one_off: true, reward_pebbles: 3)
      ChoreCompleter.new(sibling, user).call

      ctx = ChoreSerializerContext.for_user(user)
      sub_json = ChoreSerializer.new(sub, viewer: user, ctx: ctx).as_json
      sibling_json = ChoreSerializer.new(sibling, viewer: user, ctx: ctx).as_json
      parent_json = ChoreSerializer.new(parent, viewer: user, ctx: ctx).as_json

      expect(sub_json[:done_count_today]).to eq(0)
      expect(sibling_json[:done_count_today]).to eq(1)
      # Parent's done_count rolls up the sub-mediated completion.
      expect(parent_json[:done_count_today]).to eq(1)
    end

    it "exposes the parent's threshold / sharing_mode and surfaces parent_chore_id" do
      parent.update!(threshold_seconds: 7200, sharing_mode: :household)
      json = ChoreSerializer.new(sub, viewer: user).as_json
      expect(json[:threshold_seconds]).to eq(7200)
      expect(json[:sharing_mode]).to eq("household")
      expect(json[:parent_chore_id]).to eq(parent.id)
    end
  end

  describe ChoreDailyResetWorker, "hot-pick eligibility" do
    it "no longer excludes one-offs from the hot pick pool" do
      one_off = create(:chore, created_by_user: user, one_off: true, reward_pebbles: 3)
      day = ChoreDay.current(user)
      # Force a deterministic outcome: only candidate in the pool.
      Chore.where.not(id: one_off.id).update_all(archived_at: Time.current)
      described_class.new.generate_hot_picks!(day)
      expect(ChoreHotPick.where(day_key: day, chore_id: one_off.id)).to exist
    end

    it "archive_completed_one_offs! archives sub-chores via sub_chore_id" do
      sub = create(:chore, created_by_user: user, parent_chore: parent, one_off: true, reward_pebbles: 3)
      yesterday = ChoreDay.current(user) - 1
      ChoreCompletion.create!(
        chore: parent,
        sub_chore_id: sub.id,
        user: user,
        completed_at: yesterday.to_time + 12.hours,
        day_key: yesterday,
        base_pebbles: 3,
        paid_pebbles: 3,
      )
      described_class.new.archive_completed_one_offs!(ChoreDay.current(user))
      expect(sub.reload.archived_at).to be_present
      # Parent must NOT archive — only one-offs get archived.
      expect(parent.reload.archived_at).to be_nil
    end
  end
end

RSpec.describe "future marked_due_at gating", type: :model do
  let(:user) { create(:user) }

  it "hides a one-off whose marked_due_at is in the future from today_visible?" do
    chore = create(:chore, created_by_user: user, one_off: true, marked_due_at: 3.days.from_now)
    json = ChoreSerializer.new(chore, viewer: user).as_json
    expect(json[:today_visible]).to eq(false)
  end

  it "shows a one-off whose marked_due_at is today" do
    chore = create(:chore, created_by_user: user, one_off: true, marked_due_at: Time.current)
    json = ChoreSerializer.new(chore, viewer: user).as_json
    expect(json[:today_visible]).to eq(true)
  end

  it "hides a recurring chore whose marked_due_at is in the future, even when its schedule fires today" do
    chore = create(
      :chore,
      created_by_user: user,
      one_off:         false,
      recurrence:      { freq: "daily" },
      marked_due_at:   3.days.from_now,
    )
    json = ChoreSerializer.new(chore, viewer: user).as_json
    expect(json[:today_visible]).to eq(false)
  end

  it "still shows a recurring scheduled-today chore when marked_due_at is nil" do
    chore = create(
      :chore,
      created_by_user: user,
      one_off:         false,
      recurrence:      { freq: "daily" },
      marked_due_at:   nil,
    )
    json = ChoreSerializer.new(chore, viewer: user).as_json
    expect(json[:today_visible]).to eq(true)
  end
end
