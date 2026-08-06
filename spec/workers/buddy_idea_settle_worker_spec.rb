require "rails_helper"

RSpec.describe BuddyIdeaSettleWorker do
  let(:user) { User.me }
  let(:conversation) {
    ByteConversation.create!(user: user, mode: :buddy, name: "test", last_message_at: Time.current)
  }

  describe "#perform" do
    it "settles the conversation it was handed" do
      expect(Buddy::IdeaDwell).to receive(:settle!).with(conversation, over: false)

      described_class.new.perform(conversation.id)
    end

    it "passes on a caller that already knows the stretch is over" do
      expect(Buddy::IdeaDwell).to receive(:settle!).with(conversation, over: true)

      described_class.new.perform(conversation.id, true)
    end

    it "shrugs off a conversation that's since been deleted" do
      expect(Buddy::IdeaDwell).not_to receive(:settle!)

      expect { described_class.new.perform(-1) }.not_to raise_error
    end
  end
end
