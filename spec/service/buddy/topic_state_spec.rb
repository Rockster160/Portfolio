require "rails_helper"

# Short-term memory with a topic attached.
#
# History was already everything since `buddy_recap_at`, cut by Buddy::Compactor
# on SIZE and ELAPSED TIME. Both are facts about how long the transcript is;
# neither is a fact about what it's about. This is the missing axis, and it
# doesn't touch either — the verbatim messages stay exactly as they were.
RSpec.describe Buddy::TopicState do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

  def say(body, direction: :outbound, meta: {})
    convo.byte_messages.create!(
      user: user, direction: direction, state: :delivered, body: body, metadata: meta,
    )
  end

  def exchange(lines)
    lines.each_with_index { |line, i| say(line, direction: i.even? ? :outbound : :inbound, meta: i.even? ? {} : { "kind" => "buddy" }) }
  end

  def stub_client(text)
    fake = FakeBuddyClient.new([{ text: text }])
    allow(Buddy::GPT::Client).to receive(:new).and_return(fake)
    fake
  end

  let(:greenhouse) {
    [
      "I want to sort out the greenhouse before autumn",
      "What's the state of it now?",
      "The glazing is cracked on the north side and there's no power out there",
      "Power first, then glazing?",
      "Probably. I'd want a heated propagation bench eventually",
      "Then the run of power decides where the bench goes.",
    ]
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  describe "settling a topic" do
    it "writes down what the conversation is currently on" do
      exchange(greenhouse)
      stub_client("They're planning a greenhouse refit before autumn, power first then glazing.")

      described_class.settle!(convo)

      expect(convo.reload.buddy_topic).to include("greenhouse")
      expect(convo.buddy_topic_at).to be_present
    end

    # Three messages is an exchange, not a topic — and a lower bar would mean a
    # model call on someone saying hello and being answered.
    it "does not reach for a model on an exchange too short to be a topic" do
      exchange(greenhouse.first(3))
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(convo)).to be_nil
    end

    it "stores nothing when there's no thread running through the last few messages" do
      exchange(["hey", "Hey hey!", "nothing much", "Fair enough.", "yeah", "Mm."])
      stub_client(described_class::NONE)

      described_class.settle!(convo)

      expect(convo.reload.buddy_topic).to be_nil
    end

    it "clears a stale topic when the conversation stops having one" do
      convo.update_columns(buddy_topic: "the greenhouse refit", buddy_topic_at: 1.hour.ago)
      exchange(["what's for dinner", "Pasta?", "sure", "Nice.", "ok", "Cool."])
      stub_client(described_class::NONE)

      described_class.settle!(convo)

      expect(convo.reload.buddy_topic).to be_nil
    end
  end

  describe "what counts as a change" do
    it "leaves a live topic alone rather than re-distilling it every turn" do
      convo.update_columns(buddy_topic: "planning the greenhouse refit, power then glazing")
      exchange(greenhouse)
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.settle!(convo)).to be_nil
    end

    it "notices when the conversation has moved somewhere else entirely" do
      convo.update_columns(buddy_topic: "planning the greenhouse refit, power then glazing")
      exchange(greenhouse)
      exchange(["did the parcel turn up", "It did, this morning.", "great", "Want it opened?"])
      stub_client("They're checking on a delivery that arrived this morning.")

      described_class.settle!(convo)

      expect(convo.reload.buddy_topic).to include("delivery")
    end

    # A compaction knows the exchange is about to leave Buddy's view, so it is
    # the last moment the topic can be captured at all.
    it "settles regardless when the caller already knows the stretch is over" do
      convo.update_columns(buddy_topic: "planning the greenhouse refit, power then glazing")
      exchange(greenhouse)
      stub_client("They settled on running power before reglazing.")

      expect(described_class.settle!(convo, over: true)).to include("power")
    end
  end

  describe "the prompt block" do
    it "is nil for a thread with no topic, so it costs nothing" do
      expect(described_class.block_for(convo)).to be_nil
    end

    it "says what they're on and tells the model not to steer back to it" do
      convo.update_columns(buddy_topic: "planning the greenhouse refit")

      block = described_class.block_for(convo)

      expect(block).to include("planning the greenhouse refit")
      expect(block).to match(/don't steer back/i)
    end

    it "rides in the real system prompt" do
      convo.update_columns(buddy_topic: "planning the greenhouse refit")

      prompt = Buddy::Personality.for(user, conversation: convo)

      expect(prompt).to include("planning the greenhouse refit")
    end
  end

  describe "resilience" do
    it "leaves the stored topic alone when the model call fails" do
      convo.update_columns(buddy_topic: "the greenhouse refit")
      exchange(greenhouse)
      exchange(["did the parcel turn up", "It did.", "great", "Want it opened?"])
      allow(Buddy::GPT::Client).to receive(:new).and_return(FakeBuddyClient.new([{ error: "rate limited" }]))

      described_class.settle!(convo)

      expect(convo.reload.buddy_topic).to eq("the greenhouse refit")
    end

    it "skips hidden seeds and chips when reading the stretch" do
      exchange(greenhouse)
      say("hidden seed", meta: { "hidden" => true, "kind" => "buddy_trigger" })
      fake = stub_client("They're planning a greenhouse refit.")

      described_class.settle!(convo)

      expect(fake.calls.first.input.first[:content]).not_to include("hidden seed")
    end
  end
end
