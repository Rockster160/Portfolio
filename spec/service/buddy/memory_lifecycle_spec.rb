require "rails_helper"

# Memory lifecycle: short-term expiry, priority/recency recall, and
# reinforcement-on-re-mention (the "still relevant" signal). Durable facts
# (null expires_at) are never auto-pruned.
RSpec.describe "BuddyMemory lifecycle" do
  let(:user) { create(:user) }

  def remember(body)
    Buddy::SideEffects.apply_remember(user, body)
  end

  describe "BuddyMemory scopes" do
    it "active excludes expired, for_recall orders by priority then recency" do
      past   = BuddyMemory.create!(user: user, content: "expired one",  expires_at: 1.hour.ago)
      hi     = BuddyMemory.create!(user: user, content: "important",    priority: 5)
      lo_old = BuddyMemory.create!(user: user, content: "old low",      priority: 0, created_at: 2.days.ago)
      lo_new = BuddyMemory.create!(user: user, content: "new low",      priority: 0)

      expect(BuddyMemory.active).not_to include(past)
      expect(BuddyMemory.where(user: user).for_recall.to_a).to eq([hi, lo_new, lo_old])
    end
  end

  describe ".apply_remember" do
    it "stores a durable fact with no expiry" do
      expect { remember("Rocco takes coffee 8oz oat milk") }.to change { BuddyMemory.count }.by(1)
      m = BuddyMemory.last
      expect(m.expires_at).to be_nil
      expect(m.last_used_at).to be_present
    end

    it "sets an expiry for a short-term fact (`| 2 weeks`)" do
      remember("Rocco is heads-down on the launch | 2 weeks")
      m = BuddyMemory.last
      expect(m.content).to eq("Rocco is heads-down on the launch")
      expect(m.expires_at).to be_within(1.day).of(2.weeks.from_now)
    end

    it "reinforces an existing fact instead of duplicating it" do
      remember("Rocco takes coffee 8oz oat milk")
      original = BuddyMemory.last
      expect(original.priority).to eq(0)

      expect { remember("Rocco takes coffee 8oz oat milk") }.not_to change { BuddyMemory.count }
      original.reload
      expect(original.priority).to eq(1)          # bumped
      expect(original.last_used_at).to be_present  # touched
    end
  end

  describe BuddyMemoryPruneWorker do
    it "deletes expired memories but keeps durable ones" do
      expired = BuddyMemory.create!(user: user, content: "gone", expires_at: 1.minute.ago)
      durable = BuddyMemory.create!(user: user, content: "coffee = oat milk", expires_at: nil)

      described_class.new.perform

      expect(BuddyMemory.exists?(expired.id)).to be(false)
      expect(BuddyMemory.exists?(durable.id)).to be(true)
    end
  end
end
