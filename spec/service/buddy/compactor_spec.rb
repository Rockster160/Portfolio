require "rails_helper"

RSpec.describe Buddy::Compactor do
  let(:user) { User.me }
  let(:conversation) {
    ByteConversation.create!(user: user, mode: :buddy, name: "test", last_message_at: Time.current)
  }

  # Thresholds are percentages of the window left AFTER the fixed prompt + tool
  # cost, so tests size their fixtures against that rather than the raw window.
  let(:available) { described_class::AVAILABLE_WINDOW }

  def tokens_worth(count)
    "x" * (Buddy::TokenEstimator::CHARS_PER_TOKEN * count)
  end

  def say(body, direction: :outbound)
    conversation.byte_messages.create!(
      user: user, direction: direction, state: :delivered, body: body,
      metadata: (direction == :inbound ? { "kind" => "buddy" } : {})
    )
  end

  before { conversation.byte_messages.destroy_all }

  describe ".should_compact?" do
    it "returns nil when the conversation is small" do
      say("hi")
      conversation.update!(last_message_at: Time.current)

      expect(described_class.should_compact?(conversation)).to be_nil
    end

    it "returns :hard when history crosses 20% of the available window" do
      say(tokens_worth((available * 0.21).to_i))
      conversation.update!(last_message_at: Time.current)

      expect(described_class.should_compact?(conversation)).to eq(:hard)
    end

    it "returns :soft when history is over 10% AND the last reply was over 20 min ago" do
      say(tokens_worth((available * 0.12).to_i))
      conversation.update!(last_message_at: 25.minutes.ago)

      expect(described_class.should_compact?(conversation)).to eq(:soft)
    end

    it "returns nil when history is over 10% but the conversation is still active" do
      say(tokens_worth((available * 0.12).to_i))
      conversation.update!(last_message_at: 30.seconds.ago)

      expect(described_class.should_compact?(conversation)).to be_nil
    end

    it "does not fire on a fresh conversation just from the fixed prompt overhead" do
      # Regression guard: the thresholds used to be measured against the raw
      # context window, where the ~23k of prompt + schemas alone was already
      # 18% and every new thread compacted on its first message.
      say("morning")
      conversation.update!(last_message_at: 2.hours.ago)

      expect(described_class.should_compact?(conversation)).to be_nil
    end
  end

  describe ".compact!" do
    before do
      say("I've been stressed about the launch")
      say("That sounds heavy. Want to talk it through?", direction: :inbound)
    end

    def stub_client(rounds)
      fake = FakeBuddyClient.new(rounds)
      allow(Buddy::GPT::Client).to receive(:new).and_return(fake)
      fake
    end

    it "stores the summary on conversation metadata on success" do
      stub_client([{ text: "We talked about launch stress." }])

      recap = described_class.compact!(conversation)

      expect(recap).to eq("We talked about launch stress.")
      expect(conversation.reload.metadata["buddy_recap"]).to eq("We talked about launch stress.")
      expect(conversation.metadata["buddy_recap_at"]).to be_present
    end

    it "summarizes over the conversation history, not a bare prompt" do
      fake = stub_client([{ text: "recap" }])

      described_class.compact!(conversation)

      roles = fake.calls.first.input.pluck(:role)
      expect(roles).to include(:user, :assistant)
      expect(fake.calls.first.input.last[:content]).to match(/summarize/i)
    end

    it "returns nil and leaves metadata alone when the model call fails" do
      stub_client([{ error: "rate limited" }])

      recap = described_class.compact!(conversation)

      expect(recap).to be_nil
      expect(conversation.reload.metadata["buddy_recap"]).to be_nil
    end

    it "returns nil without calling the model when there's nothing worth summarizing" do
      conversation.byte_messages.destroy_all
      expect(Buddy::GPT::Client).not_to receive(:new)

      expect(described_class.compact!(conversation)).to be_nil
    end

    it "records its own cost separately, with no message attached" do
      stub_client([{ text: "recap" }])

      described_class.compact!(conversation)

      row = BuddyUsage.last
      expect(row).to be_compaction
      expect(row.byte_message_id).to be_nil
      expect(row.byte_conversation_id).to eq(conversation.id)
      expect(row.cost_micros).to be > 0
    end

    it "drops the token estimate back down once a recap is stored" do
      say(tokens_worth((available * 0.21).to_i))
      stub_client([{ text: "recap here" }])

      described_class.compact!(conversation)

      # Only messages created AFTER buddy_recap_at count, so the estimate falls
      # back to roughly the recap alone.
      tokens = Buddy::TokenEstimator.estimate_for(conversation.reload)
      expect(tokens).to be < described_class::SOFT_PCT * available
    end
  end
end
