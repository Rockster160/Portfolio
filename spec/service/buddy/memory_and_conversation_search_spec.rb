require "rails_helper"

# The two ways back to something that isn't in front of Buddy.
#
# `search_memories` reaches what Buddy chose to KEEP, which is everything except
# standing preferences now that MEMORY_RECALL_LIMIT is gone.
# `search_conversations` reaches what was actually SAID, for the times nothing
# was kept because at the moment it was said it didn't look worth keeping.
RSpec.describe "Buddy recall" do
  let(:user)  { User.me }
  let(:other) { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  def ctx = Buddy::ToolContext.new(user, conversation: convo)

  def answer(name, payload = {})
    Buddy::GPT::Turn.resolve_tool(
      Buddy::Tools[name],
      { call_id: "call_1", name: name, arguments: payload },
      user: user, conversation: convo,
    )
  end

  before { BuddyMemory.where(user: [user, other]).destroy_all }

  describe "search_memories" do
    it "settles inside the turn rather than leaving a row to tap" do
      expect(Buddy::Tools.answers?(Buddy::Tools[:search_memories])).to be(true)
    end

    it "finds by tag, which is how a subject in the conversation reaches a memory" do
      packed = user.buddy_memories.create!(
        kind: :concept, content: "Forgot the sleeping bags on the last camping trip.",
        tags: %w[camping gear], severity: 20,
      )
      user.buddy_memories.create!(kind: :concept, content: "The boiler needs bleeding.", tags: %w[house])

      out = answer(:search_memories, { tags: "camping" })

      expect(out[:total]).to eq(1)
      expect(out[:memories].join(" ")).to include("##{packed.id}", "sleeping bags")
    end

    # The whole reason the cap had to go: a fact mentioned once and never
    # repeated sorted LAST under the old priority ordering, so it was first over
    # the side — and that is exactly the shape of the memories worth keeping.
    it "reaches a never-reinforced memory that the old 30-row cap would have dropped" do
      35.times { |i| user.buddy_memories.create!(kind: :preference, content: "filler preference #{i}", priority: 50) }
      once = user.buddy_memories.create!(kind: :concept, content: "Pharmacy shuts early on Sundays.", priority: 0)

      out = answer(:search_memories, { query: "pharmacy" })

      expect(out[:memories].join(" ")).to include("##{once.id}")
    end

    it "matches a stash category by the same term, so the caller needn't know which field holds it" do
      held = user.buddy_memories.create!(kind: :stash, content: "chase the invoice", category: :work)

      out = answer(:search_memories, { tags: "work" })

      expect(out[:memories].join(" ")).to include("##{held.id}")
    end

    it "narrows to what actually matters with min_severity" do
      heavy = user.buddy_memories.create!(kind: :followup, content: "mum's surgery next week", severity: 80, tags: %w[family])
      user.buddy_memories.create!(kind: :concept, content: "family likes board games", severity: 5, tags: %w[family])

      out = answer(:search_memories, { tags: "family", min_severity: 50 })

      expect(out[:showing]).to eq(1)
      expect(out[:memories].join(" ")).to include("##{heavy.id}")
    end

    it "never reaches another person's memories" do
      other.buddy_memories.create!(kind: :concept, content: "their private camping thought", tags: %w[camping])

      out = answer(:search_memories, { tags: "camping" })

      expect(out[:total]).to eq(0)
      expect(out[:how]).to include("Nothing matched")
    end

    it "searches the notes on a thread, not just the seed" do
      held = user.buddy_memories.create!(kind: :stash, content: "that garden thing")
      held.notes.create!(body: "hydroponics might be the answer")

      out = answer(:search_memories, { query: "hydroponics" })

      expect(out[:memories].join(" ")).to include("##{held.id}")
    end
  end

  describe "search_conversations" do
    def say(body, direction: :outbound, at: Time.current, meta: {}, thread: convo)
      thread.byte_messages.create!(
        user: user, direction: direction, state: :delivered,
        body: body, metadata: meta, created_at: at,
      )
    end

    it "settles inside the turn rather than leaving a row to tap" do
      expect(Buddy::Tools.answers?(Buddy::Tools[:search_conversations])).to be(true)
    end

    it "finds what they said and hands back enough to answer from" do
      say("I need to pick my cousins up from the airport on the 14th", at: 3.days.ago)
      say("what's for dinner", at: 2.days.ago)

      out = answer(:search_conversations, { query: "airport" })

      expect(out[:total]).to eq(1)
      expect(out[:messages].first).to include("cousins", "airport", user.first_name)
    end

    # A quick-action seed is not something the person wrote. Returning them is
    # how "what did I say about the airport" comes back with prompts nobody
    # typed.
    it "skips hidden seeds, receipt chips and watch-fired posts" do
      say("real airport message")
      say("hidden airport seed", meta: { "hidden" => true, "kind" => "buddy_trigger" })
      say("airport chip", direction: :inbound, meta: { "kind" => "buddy_activity" })
      say("airport watch", direction: :inbound, meta: { "kind" => "buddy", "source" => "watch" })

      out = answer(:search_conversations, { query: "airport" })

      expect(out[:total]).to eq(1)
      expect(out[:messages].first).to include("real airport message")
    end

    it "stays in this thread by default and reaches all of theirs on request" do
      moss = user.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current)
      say("the greenhouse rewire", thread: moss)

      expect(answer(:search_conversations, { query: "greenhouse" })[:total]).to eq(0)

      out = answer(:search_conversations, { query: "greenhouse", scope: "all" })
      expect(out[:total]).to eq(1)
      expect(out[:messages].first).to include("Moss")
    end

    it "never reaches another person's threads" do
      theirs = other.byte_conversations.create!(mode: :buddy, name: "Eve", last_message_at: Time.current)
      theirs.byte_messages.create!(
        user: other, direction: :outbound, state: :delivered, body: "my own airport plans",
      )

      out = answer(:search_conversations, { query: "airport", scope: "all" })

      expect(out[:total]).to eq(0)
    end

    it "narrows by days when they've said 'earlier today'" do
      say("airport run", at: 40.days.ago)

      expect(answer(:search_conversations, { query: "airport" })[:total]).to eq(1)
      expect(answer(:search_conversations, { query: "airport", days: 7 })[:total]).to eq(0)
    end

    it "requires every word, so two terms narrow rather than widen" do
      say("the airport on Tuesday")
      say("the airport on Friday")

      expect(answer(:search_conversations, { query: "airport Tuesday" })[:total]).to eq(1)
    end

    it "says plainly when nothing matched rather than reconstructing" do
      out = answer(:search_conversations, { query: "submarine" })

      expect(out[:total]).to eq(0)
      expect(out[:how]).to include("you don't know it")
    end
  end
end
