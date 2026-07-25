require "rails_helper"

RSpec.describe Buddy::Compactor do
  let(:user) { User.me }
  let(:conversation) {
    ByteConversation.create!(user: user, mode: :buddy, name: "test", last_message_at: Time.current)
  }

  before { conversation.byte_messages.destroy_all }

  describe ".should_compact?" do
    it "returns nil when the conversation is small" do
      conversation.byte_messages.create!(user: user, direction: :outbound, state: :delivered, body: "hi")
      conversation.update!(last_message_at: Time.current)

      expect(described_class.should_compact?(conversation)).to be_nil
    end

    it "returns :hard when tokens cross 20% (40k)" do
      big = "x" * (Buddy::TokenEstimator::CHARS_PER_TOKEN * 45_000)
      conversation.byte_messages.create!(user: user, direction: :outbound, state: :delivered, body: big)
      conversation.update!(last_message_at: Time.current)

      expect(described_class.should_compact?(conversation)).to eq(:hard)
    end

    it "returns :soft when tokens > 10% AND last reply was > 20 min ago" do
      medium = "x" * (Buddy::TokenEstimator::CHARS_PER_TOKEN * 22_000)
      conversation.byte_messages.create!(user: user, direction: :outbound, state: :delivered, body: medium)
      conversation.update!(last_message_at: 25.minutes.ago)

      expect(described_class.should_compact?(conversation)).to eq(:soft)
    end

    it "returns nil when tokens > 10% but conversation is still active" do
      medium = "x" * (Buddy::TokenEstimator::CHARS_PER_TOKEN * 22_000)
      conversation.byte_messages.create!(user: user, direction: :outbound, state: :delivered, body: medium)
      conversation.update!(last_message_at: 30.seconds.ago)

      expect(described_class.should_compact?(conversation)).to be_nil
    end
  end

  describe ".compact!" do
    it "stores the summary on conversation metadata on success" do
      allow(ByteLocal).to receive(:compact_buddy_session).and_return({ "summary" => "we chatted about coffee" })

      recap = described_class.compact!(conversation)

      expect(recap).to eq("we chatted about coffee")
      expect(conversation.reload.metadata["buddy_recap"]).to eq("we chatted about coffee")
      expect(conversation.metadata["buddy_recap_at"]).to be_present
    end

    it "returns nil and leaves metadata alone when the Mac call fails" do
      allow(ByteLocal).to receive(:compact_buddy_session).and_return(nil)

      recap = described_class.compact!(conversation)

      expect(recap).to be_nil
      expect(conversation.reload.metadata["buddy_recap"]).to be_nil
    end

    it "resets the token estimator baseline once a recap is stored" do
      big = "x" * (Buddy::TokenEstimator::CHARS_PER_TOKEN * 45_000)
      conversation.byte_messages.create!(user: user, direction: :outbound, state: :delivered, body: big)
      allow(ByteLocal).to receive(:compact_buddy_session).and_return({ "summary" => "recap here" })

      described_class.compact!(conversation)

      # After compact, only messages created AFTER buddy_recap_at count,
      # so token estimate drops back near baseline + recap.
      tokens = Buddy::TokenEstimator.estimate_for(conversation.reload)
      expect(tokens).to be < Buddy::Compactor::SOFT_PCT * Buddy::Compactor::CTX_WINDOW
    end
  end
end
