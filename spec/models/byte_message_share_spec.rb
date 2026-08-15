require "rails_helper"

# One message, two threads, one row.
#
# The doorbell frame is a single event, and it used to be delivered by writing
# the row twice and keeping the pair in step by hand — CompanionRelay#bridge!
# linking them with `metadata["relay_twin"]`, Buddy::Reactions writing every
# tapback to both so one person's 👍 showed for the other. A share replaces the
# mirroring with a pointer: react to the row and both people are looking at the
# thing that changed.
RSpec.describe ByteMessageShare do
  let(:rocco)   { create(:user) }
  let(:chelsea) { create(:user) }
  let(:home)    { rocco.byte_conversations.create!(mode: :buddy, name: "Byte") }
  let(:hers)    { chelsea.byte_conversations.create!(mode: :buddy, name: "Moss") }
  let(:message) {
    home.byte_messages.create!(
      user: rocco, direction: :inbound, state: :delivered,
      body: "🔔 Someone's at the door"
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  describe ".share!" do
    it "shows the message in the other thread without copying it" do
      message # created up front, so the block below counts only what sharing does

      expect { described_class.share!(message, hers) }.not_to change(ByteMessage, :count)

      expect(hers.visible_messages).to include(message)
      expect(hers.byte_messages).not_to include(message)
    end

    it "leaves the message where it was authored" do
      described_class.share!(message, hers)

      expect(message.reload.byte_conversation).to eq(home)
      expect(home.visible_messages).to include(message)
    end

    # The delivery paths are notification paths, and those can fire twice.
    it "is idempotent" do
      described_class.share!(message, hers)

      expect { described_class.share!(message, hers) }.not_to change(described_class, :count)
    end

    it "refuses to share a message into the thread that already owns it" do
      expect(described_class.share!(message, home)).to be_nil
      expect(home.visible_messages.where(id: message.id).count).to eq(1)
    end

    it "records the recipient so unread and inbox scoping don't have to join" do
      expect(described_class.share!(message, hers).user).to eq(chelsea)
    end
  end

  describe "what the recipient's client is told" do
    # The client routes every frame by the conversation it names. Labelled with
    # its home id, a share arrives addressed to a thread the recipient can't
    # see, and is dropped.
    it "addresses the frame to the recipient's own thread" do
      described_class.share!(message, hers)

      expect(MonitorChannel).to have_received(:broadcast_to).with(
        chelsea, hash_including(data: hash_including(message: hash_including(conversation_id: hers.id)))
      )
    end

    it "still labels the owner's own copy with the home thread" do
      expect(message.as_wire[:conversation_id]).to eq(home.id)
    end
  end

  describe "reading a thread" do
    it "orders a shared message by when it happened, not when it was shared" do
      older = home.byte_messages.create!(
        user: rocco, direction: :inbound, state: :delivered,
        body: "earlier", created_at: 2.hours.ago
      )
      mine = hers.byte_messages.create!(
        user: chelsea, direction: :outbound, state: :sent,
        body: "hers", created_at: 1.hour.ago
      )
      described_class.share!(older, hers)

      expect(hers.visible_messages.chronological.pluck(:body)).to eq(["earlier", "hers"])
    end

    it "does not leak a message into a thread it was never shared with" do
      other = chelsea.byte_conversations.create!(mode: :buddy, name: "Other")
      described_class.share!(message, hers)

      expect(other.visible_messages).not_to include(message)
    end
  end

  describe "tearing things down" do
    # A share is a pointer. Dropping the thread that was shown the message must
    # never take the message with it - it belongs to whoever produced it.
    it "drops the share and keeps the message when the recipient's thread goes" do
      described_class.share!(message, hers)

      hers.destroy

      expect(ByteMessage.exists?(message.id)).to be(true)
      expect(described_class.count).to eq(0)
    end

    it "drops the share when the message itself goes" do
      described_class.share!(message, hers)

      message.destroy

      expect(described_class.count).to eq(0)
    end
  end

  describe "reactions" do
    it "are shared by construction - one row, so one list" do
      described_class.share!(message, hers)

      Buddy::Reactions.react!(message: message, user: chelsea, emoji: "👍")

      shown = hers.visible_messages.find(message.id)
      expect(shown.metadata["reactions"].pluck("emoji")).to eq(["👍"])
      expect(home.visible_messages.find(message.id).metadata["reactions"].length).to eq(1)
    end

    it "tells both people, each addressed to their own thread" do
      described_class.share!(message, hers)

      Buddy::Reactions.react!(message: message, user: rocco, emoji: "❤️")

      expect(MonitorChannel).to have_received(:broadcast_to).with(
        chelsea, hash_including(data: hash_including(update: true, message: hash_including(conversation_id: hers.id)))
      )
      expect(MonitorChannel).to have_received(:broadcast_to).with(
        rocco, hash_including(data: hash_including(update: true, message: hash_including(conversation_id: home.id)))
      )
    end
  end
end
