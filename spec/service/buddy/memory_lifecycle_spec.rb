require "rails_helper"

# Memory lifecycle: short-term expiry, priority/recency recall, and
# reinforcement-on-re-mention (the "still relevant" signal). Durable facts
# (null expires_at) are never auto-pruned.
RSpec.describe "BuddyMemory lifecycle" do
  let(:user) { create(:user) }

  def remember(fact, expires_in: nil)
    Buddy::SideEffects.apply_remember(user, fact, expires_in)
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

    it "sets an expiry for a short-term fact via expires_in" do
      remember("Rocco is heads-down on the launch", expires_in: "2 weeks")
      m = BuddyMemory.last
      expect(m.content).to eq("Rocco is heads-down on the launch")
      expect(m.expires_at).to be_within(1.day).of(2.weeks.from_now)
    end

    it "treats an unparseable expires_in as durable rather than guessing" do
      remember("Rocco likes oat milk", expires_in: "for a bit")
      expect(BuddyMemory.last.expires_at).to be_nil
    end

    # The prompt has always asked for `expires_in` on short-term facts, and it
    # gets skipped anyway: "doesn't want to do anything after the ceremony ends
    # at 8:30 PM today" was stored as a permanent truth about someone, injected
    # into every turn after it and already wrong by that evening.
    it "expires a fact about today even when the model forgot to say so" do
      remember("Doesn't want to do anything after the ceremony ends at 8:30 PM today")

      # The end of their PERCEIVED day (Buddy's 3am rollover), same as an
      # explicit `expires_in: "today"` — someone still up at 1am is in the day
      # the calendar left an hour ago.
      expect(BuddyMemory.last.expires_at).to eq(Buddy::Day.range(user, date: Buddy::Day.today(user)).last)
    end

    it "catches the other same-day wordings" do
      ["Feeling rough this morning", "Wants a quiet evening tonight", "Is at her mum's right now"].each { |fact|
        remember(fact)
        expect(BuddyMemory.last.expires_at).to be_present, "expected #{fact.inspect} to expire"
      }
    end

    it "leaves a genuinely durable fact durable" do
      remember("Works from home on Fridays")

      expect(BuddyMemory.last.expires_at).to be_nil
    end

    it "doesn't override an expiry the model did pass" do
      remember("Heads-down on the launch today and all week", expires_in: "2 weeks")

      expect(BuddyMemory.last.expires_at).to be_within(1.day).of(2.weeks.from_now)
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

  # Reinforcement has to survive being said DIFFERENTLY, or it never fires for
  # someone who thinks out loud - nobody repeats themselves word for word, and
  # a fact re-mentioned five ways used to become five rows at priority zero.
  describe "reinforcement across rewordings" do
    it "bumps the fact we hold when the same thing is said another way" do
      remember("Ryker has soccer on Tuesdays")
      held = BuddyMemory.last

      expect { remember("Ryker's soccer is on a Tuesday") }.not_to change { BuddyMemory.count }
      expect(held.reload.priority).to eq(1)
      expect(held.content).to eq("Ryker has soccer on Tuesdays") # reinforced, not churned
    end

    it "keeps two facts about one subject apart" do
      remember("Ryker plays soccer")

      expect { remember("Ryker plays piano") }.to change { BuddyMemory.count }.by(1)
    end

    it "takes the fuller wording when a re-mention spells the fact out" do
      remember("Ryker has soccer")
      held = BuddyMemory.last

      expect { remember("Ryker has soccer on Tuesdays at 4") }.not_to change { BuddyMemory.count }
      expect(held.reload.content).to eq("Ryker has soccer on Tuesdays at 4")
      expect(held.priority).to eq(1)
    end

    it "doesn't collapse two facts that only share filler words" do
      remember("Eve is going to the shop")

      expect { remember("Eve is going to the doctor") }.to change { BuddyMemory.count }.by(1)
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
