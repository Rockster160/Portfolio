require "rails_helper"

RSpec.describe "BuddyMemory lifecycle" do
  # Memory lifecycle: short-term expiry, priority/recency recall, and
  # reinforcement-on-re-mention (the "still relevant" signal). Durable facts
  # (null expires_at) are never auto-pruned.
  describe "lifecycle" do
    let(:user) { create(:user) }

    def remember(fact, expires_in: nil, check_in_days: nil)
      Buddy::SideEffects.apply_remember(user, fact, expires_in, check_in_days)
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

    # What ships inline in every prompt. A dated preference is held back until
    # its day, and undoing a `remember` sets `dropped` (Buddy::Reverter).
    it "always_loaded carries undated and due preferences, never early or dropped ones", :aggregate_failures do
      early   = BuddyMemory.create!(user: user, content: "Period about 6 days away", kind: :preference, relevant_at: 4.days.from_now)
      due     = BuddyMemory.create!(user: user, content: "Period is due", kind: :preference, relevant_at: 1.hour.ago)
      plain   = BuddyMemory.create!(user: user, content: "Takes coffee 8oz oat milk", kind: :preference)
      dropped = BuddyMemory.create!(user: user, content: "Wrong thing", kind: :preference, status: :dropped)

      loaded = BuddyMemory.where(user: user).always_loaded
      expect(loaded).to include(due, plain)
      expect(loaded).not_to include(early, dropped)
    end

    describe ".apply_remember" do
      it "stores a durable fact with no expiry and marks it used" do
        expect { remember("Rocco takes coffee 8oz oat milk") }.to change { BuddyMemory.count }.by(1)
        m = BuddyMemory.last
        expect(m.expires_at).to be_nil
        expect(m.last_used_at).to be_present
      end

      # A fact about today expires with the PERCEIVED day (Buddy's 3am
      # rollover) even when the model forgot `expires_in`; an explicit one wins,
      # and an unparseable one is durable rather than a guess.
      it "works out when a fact expires", :aggregate_failures do
        end_of_today = Buddy::Day.range(user, date: Buddy::Day.today(user)).last
        [
          ["Rocco is on call for the release", "2 weeks", be_within(1.day).of(2.weeks.from_now)],
          ["Rocco likes oat milk", "for a bit", be_nil],
          ["Doesn't want to do anything after the ceremony ends at 8:30 PM today", nil, eq(end_of_today)],
          ["Feeling rough this morning", nil, be_present],
          ["Wants a quiet evening tonight", nil, be_present],
          ["Is at her mum's right now", nil, be_present],
          ["Works from home on Fridays", nil, be_nil],
          ["Heads-down on the launch today and all week", "2 weeks", be_within(1.day).of(2.weeks.from_now)],
        ].each do |fact, expires_in, expected|
          remember(fact, expires_in: expires_in)
          expect(BuddyMemory.last.expires_at).to expected, fact
        end
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

    # One fact can be both held in the prompt (`preference`) and come back to
    # (`check_in_at`) on a single row.
    describe "holding a fact AND coming back to it" do
      it "carries both, on one row, in the prompt and in the queue, and queues the job that asks it", :aggregate_failures do
        Sidekiq::Testing.fake! do
          BuddyCheckInWorker.clear
          remember("Rocco was laid off at OCS", check_in_days: 2)
          memory = BuddyMemory.last

          expect(memory).to be_kind_preference
          expect(BuddyMemory.always_loaded).to include(memory)
          expect(memory.check_in_at).to be_present
          expect(memory).to be_check_in_plannable
          expect(BuddyCheckInWorker.jobs.map { |job| job["args"] }).to eq([[memory.id]])
        end
      end

      it "never asks before the thing it is about has arrived" do
        Buddy::SideEffects.apply_remember(user, "Rocco has something coming up", nil, 2, relevant_days: 10)
        memory = BuddyMemory.last

        expect(memory.relevant_at).to be_within(1.minute).of(10.days.from_now)
        expect(memory.check_in_at).to be >= memory.relevant_at
      end

      it "arms the row a re-mention lands on when it asks to be come back to" do
        remember("Rocco is waiting on a decision")
        memory = BuddyMemory.last
        expect(memory.check_in_at).to be_nil

        remember("Rocco is waiting on a decision", check_in_days: 3)

        expect(BuddyMemory.count).to eq(1)
        expect(memory.reload.check_in_at).to be_present
        expect(memory).to be_check_in_plannable
      end

      # The rule is written down twice already - "the heavier it is the SOONER",
      # and CHECK_IN_HORIZON capping how long a heavy thing may wait - so asking
      # for the weight separately is asking for the two numbers to disagree.
      it "reads the weight off how soon they want to be asked" do
        remember("Rocco was laid off at OCS", check_in_days: 2)
        heavy = BuddyMemory.last
        remember("Rocco is waiting to hear about the allotment", check_in_days: 21)
        light = BuddyMemory.last

        expect(heavy.severity).to be > light.severity
        expect(heavy.check_in_horizon_days).to be <= 2
      end

      # "Ask me in three months" is not a check-in; it stays a plain held fact
      # rather than becoming a heavy one to justify the distance.
      it "plans nothing for an ordinary fact or a distance past the widest horizon", :aggregate_failures do
        remember("Rocco's passport is up for renewal eventually", check_in_days: 200)
        remember("Rocco takes coffee 8oz oat milk")

        BuddyMemory.where(user: user).find_each do |memory|
          expect(memory.severity).to eq(0)
          expect(memory.check_in_at).to be_nil
          expect(memory).not_to be_check_in_plannable
        end
      end

      # Placed against everything else pending - two check-ins must never land
      # in one sitting. The second is a second later because CheckIns.ordered
      # breaks ties on whole-second `created_at` over an unordered query, and
      # spacing is what is under test here, not the tie.
      it "spaces it against the check-ins already queued" do
        remember("Rocco was laid off at OCS", check_in_days: 1)
        first = BuddyMemory.last.check_in_at
        travel(1.second) { remember("Rocco's dad is having a scan", check_in_days: 1) }
        second = BuddyMemory.last.check_in_at

        expect(second).to be > first
      end
    end

    # Nobody repeats themselves word for word, so reinforcement has to survive
    # being said differently.
    describe "reinforcement across rewordings" do
      it "bumps the fact we hold when the same thing is said another way" do
        remember("Ryker has soccer on Tuesdays")
        held = BuddyMemory.last

        expect { remember("Ryker's soccer is on a Tuesday") }.not_to change { BuddyMemory.count }
        expect(held.reload.priority).to eq(1)
        expect(held.content).to eq("Ryker has soccer on Tuesdays") # reinforced, not churned
      end

      it "keeps two facts about one subject, or sharing only filler words, apart", :aggregate_failures do
        remember("Ryker plays soccer")
        expect { remember("Ryker plays piano") }.to change { BuddyMemory.count }.by(1)

        remember("Eve is going to the shop")
        expect { remember("Eve is going to the doctor") }.to change { BuddyMemory.count }.by(1)
      end

      it "takes the fuller wording when a re-mention spells the fact out" do
        remember("Ryker has soccer")
        held = BuddyMemory.last

        expect { remember("Ryker has soccer on Tuesdays at 4") }.not_to change { BuddyMemory.count }
        expect(held.reload.content).to eq("Ryker has soccer on Tuesdays at 4")
        expect(held.priority).to eq(1)
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

  # `remember` and `forget` are silent tools, so a turn that wrote to memory
  # carries a `kept` mark for the bubble to show.
  describe "the write mark" do
    let(:user)   { create(:user) }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      convo.update_columns(buddy_theme: "byte")
    }

    def reply_to(text, calls: [])
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hey")
      rounds  = calls.any? ? [{ tool_calls: calls }, { text: text }] : [{ text: text }]
      Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new(rounds))
      convo.byte_messages.where(direction: :inbound).order(:id).last
    end

    it "marks a turn that wrote or pruned a memory", :aggregate_failures do
      reply = reply_to("Got it.", calls: [
        { name: :remember, call_id: "c1", arguments: { "fact" => "Their dog is called Byte." } },
      ])
      expect(reply.metadata["kept"]).to be(true)

      user.buddy_memories.create!(kind: :preference, content: "Their dog is called Fae.", severity: 0)
      reply = reply_to("Dropped that.", calls: [
        { name: :forget, call_id: "c2", arguments: { "match" => "Fae" } },
      ])
      expect(reply.metadata["kept"]).to be(true)
    end

    # A thread note is how ONE conversation behaves, not what is held about the
    # person, so it stays unmarked like an ordinary reply.
    it "leaves an ordinary reply and a thread-scoped note unmarked", :aggregate_failures do
      expect(reply_to("Morning!").metadata["kept"]).to be_nil

      reply = reply_to("Sure.", calls: [
        { name: :add_note, call_id: "c1", arguments: { "fact" => "Keep this thread strictly work." } },
      ])
      expect(reply.metadata["kept"]).to be_nil
    end
  end
end
