require "rails_helper"

# The hands of the background memory pass.
#
# It used to answer once with a JSON blob that Rails applied, which is why it
# could only ever ADD: forty truncated labels was not enough to judge overlap,
# there was no way to look further, and nothing could fix a row already wrong.
# Every tangle found in prod on 19 Aug was something it had written and then had
# no means to repair.
RSpec.describe Buddy::Compile::Toolbox do
  let(:user) { create(:user) }
  let(:messages) { [say("The fence gate is sticking and the latch is bent.")] }
  let(:box)      { described_class.new(user: user, conversation: convo, messages: messages) }
  let(:other) { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  def say(body, direction: :outbound, at: Time.current, meta: {})
    convo.byte_messages.create!(
      user: user, direction: direction, state: :delivered, body: body, metadata: meta, created_at: at,
    )
  end

  describe "writing" do
    it "holds something new and reports the id back" do
      answer = box.call("write_memory", { "kind" => "concept", "content" => "Their gate latch is bent.", "tags" => ["home"] })

      memory = BuddyMemory.where(user: user).last
      expect(answer).to eq("held as ##{memory.id}")
      expect(memory.tag_list).to eq(["home"])
      expect(box.written).to eq([memory])
    end

    # Provenance the old path had and the tool must not lose: the stamp used to
    # be "last thing they said", which pointed both of Suki's memories at a
    # goodnight message containing neither subject.
    it "points the row at the message its content actually came from" do
      box.call("write_memory", { "kind" => "concept", "content" => "Their fence gate is sticking and the latch is bent." })

      expect(BuddyMemory.where(user: user).last.source_message).to eq(messages.first)
    end

    it "leaves provenance empty rather than pointing somewhere wrong" do
      box.call("write_memory", { "kind" => "concept", "content" => "Their dentist moved to November." })

      expect(BuddyMemory.where(user: user).last.source_message).to be_nil
    end

    it "refuses a near-duplicate and says to revise instead" do
      user.buddy_memories.create!(kind: :concept, content: "Their gate latch is bent.", severity: 0)

      answer = box.call("write_memory", { "kind" => "concept", "content" => "their gate latch is bent" })

      expect(answer).to match(/already held/)
      expect(BuddyMemory.where(user: user).count).to eq(1)
    end

    it "clamps a severity outside the scale rather than failing the write" do
      box.call("write_memory", { "kind" => "concept", "content" => "Something enormous.", "severity" => 900 })

      expect(BuddyMemory.where(user: user).last.severity).to eq(100)
    end
  end

  describe "arming a check-in" do
    # Asking about something interrupts them, so trivia is refused however
    # plainly it was asked for.
    it "refuses one on something below the floor" do
      box.call("write_memory", { "kind" => "concept", "content" => "They prefer a big mug.", "severity" => 5, "check_in_days" => 3 })

      expect(BuddyMemory.where(user: user).last.check_in_at).to be_nil
    end

    it "never lands before the thing it is about is live" do
      box.call("write_memory", {
        "kind"          => "concept",
        "content"       => "Their mother has surgery next week.",
        "severity"      => 80,
        "relevant_days" => 7,
        "check_in_days" => 1,
      })

      memory = BuddyMemory.where(user: user).last
      expect(memory.relevant_at).to be_within(1.day).of(7.days.from_now)
      expect(memory.check_in_at).to be >= memory.relevant_at
    end

    it "clears one when no days are given" do
      memory = user.buddy_memories.create!(kind: :followup, content: "Their cat is in hospital.", severity: 70, check_in_at: 2.days.from_now)

      box.call("set_check_in", { "id" => memory.id })

      expect(memory.reload.check_in_at).to be_nil
    end
  end

  describe "tidying" do
    let!(:held) {
      user.buddy_memories.create!(kind: :concept, content: "After that, clear out the pantry.", severity: 10)
    }

    it "rewrites a row in place" do
      answer = box.call("revise_memory", { "id" => held.id, "content" => "Once the bedroom is sorted, clear out the pantry." })

      expect(answer).to eq("##{held.id} rewritten")
      expect(held.reload.content).to eq("Once the bedroom is sorted, clear out the pantry.")
    end

    # A cheap model editing what somebody said about themselves. The row is what
    # everything reads, so a bad rewrite is invisible without this.
    it "keeps the wording it replaced on the thread" do
      box.call("revise_memory", { "id" => held.id, "content" => "Something quite different." })

      expect(held.reload.notes.map(&:body).join).to include("After that, clear out the pantry.")
    end

    it "says so and changes nothing when the rewrite matches what is there" do
      answer = box.call("revise_memory", { "id" => held.id, "content" => held.content })

      expect(answer).to eq("unchanged")
      expect(held.reload.notes).to be_empty
    end

    it "retires one that stopped being worth holding" do
      box.call("close_memory", { "id" => held.id, "status" => "dropped", "note" => "Duplicate of the other." })

      expect(held.reload).to be_status_dropped
      expect(held.notes.map(&:body)).to include("Duplicate of the other.")
    end
  end

  # Every tool reaches rows through the same guard, so one person's pass can
  # never touch another's record however an id arrives.
  describe "somebody else's memory" do
    let!(:theirs) { other.buddy_memories.create!(kind: :followup, content: "Their own private thing.", severity: 60) }

    it "is not reachable by any of them" do
      %w[revise_memory close_memory set_check_in].each do |tool|
        answer = box.call(tool, { "id" => theirs.id, "content" => "x", "status" => "dropped", "days" => 1 })
        expect(answer).to match(/no memory/), "#{tool} reached across users"
      end

      expect(theirs.reload).to be_status_active
      expect(theirs.content).to eq("Their own private thing.")
    end
  end

  describe "looking things up" do
    it "searches past the rows it was shown" do
      user.buddy_memories.create!(kind: :concept, content: "Their cat is called Fae.", severity: 5)

      expect(box.call("search_memories", { "query" => "cat" })).to match(/Their cat is called Fae/)
    end

    it "says so plainly when nothing matches" do
      expect(box.call("search_memories", { "query" => "nothing like this" })).to eq("nothing held matching that")
    end

    # The stretch is already in front of the model; handing it back doubles the
    # prompt for nothing.
    it "reads further back without repeating the stretch" do
      old = say("We talked about the greenhouse last week.", at: 2.days.ago)

      answer = box.call("read_conversation", {})

      expect(answer).to include(old.body)
      expect(answer).not_to include(messages.first.body)
    end

    # Without ids it can only ever be called once — there is nothing to pass as
    # `before` — so "keep going until you have what you need" is not a thing the
    # model can actually do.
    it "answers with ids and times, and says how to ask for more" do
      old = say("We talked about the greenhouse last week.", at: 2.days.ago)

      answer = box.call("read_conversation", {})

      expect(answer).to match(/^##{old.id} \[\w{3} \d+ \w{3}, \d+:\d\d[ap]m\] Them:/)
      expect(answer).to include("call again with before: #{old.id}")
    end

    it "pages further back when asked" do
      oldest = say("The very first thing.", at: 5.days.ago)
      middle = say("Something in between.", at: 2.days.ago)

      answer = box.call("read_conversation", { "before" => middle.id })

      expect(answer).to include(oldest.body)
      expect(answer).not_to include(middle.body)
    end

    it "says plainly when there is nothing older left" do
      first = say("The very first thing.", at: 5.days.ago)

      expect(box.call("read_conversation", { "before" => first.id })).to match(/start of the thread/)
    end

    it "keeps chips and hidden seeds out of what it reads back" do
      say("chip", direction: :inbound, at: 2.days.ago, meta: { "kind" => "buddy_activity" })

      expect(box.call("read_conversation", {})).not_to include("chip")
    end
  end

  it "answers rather than raising when a tool fails" do
    expect(box.call("write_memory", { "kind" => "concept", "content" => "x" * 10_000 })).to be_a(String)
  end

  it "says so for a tool that doesn't exist" do
    expect(box.call("wander_off", {})).to eq("no such tool")
  end
end
