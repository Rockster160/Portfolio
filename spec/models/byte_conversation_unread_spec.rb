require "rails_helper"

# The count used to live only in the page: a reload wiped it, and anything that
# arrived while the app was closed was never counted at all, because counting
# only happened in response to a live broadcast.
RSpec.describe ByteConversation do
  let(:user) { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_read_at: 1.hour.ago) }

  def landed(at: 1.minute.ago, state: :delivered, direction: :inbound, metadata: {})
    convo.byte_messages.create!(
      user: user, direction: direction, state: state, body: "hi",
      created_at: at, metadata: metadata
    )
  end

  describe "#unread_count" do
    it "counts what arrived after the thread was last read" do
      landed
      landed

      expect(convo.unread_count).to eq(2)
    end

    it "ignores what was already there when it was read" do
      landed(at: 2.hours.ago)

      expect(convo.unread_count).to eq(0)
    end

    # The bug that started all of this: a Claude turn re-broadcasts the same row
    # as it streams, so anything counting mid-flight states counts one reply
    # many times.
    it "ignores messages still in flight" do
      landed(state: :streaming)
      landed(state: :pending)
      landed(state: :queued)

      expect(convo.unread_count).to eq(0)
    end

    it "counts a failure, which is terminal and worth seeing" do
      landed(state: :failed)

      expect(convo.unread_count).to eq(1)
    end

    it "ignores the person's own messages" do
      landed(direction: :outbound)

      expect(convo.unread_count).to eq(0)
    end

    it "ignores receipt chips, action pills and hidden trigger seeds" do
      landed(metadata: { "kind" => "buddy_activity" })
      landed(metadata: { "kind" => "action_chip" })
      landed(metadata: { "kind" => "buddy_trigger" })
      landed(metadata: { "hidden" => true })

      expect(convo.unread_count).to eq(0)
    end

    it "counts what a person would actually read" do
      landed(metadata: { "kind" => "claude" })
      landed(metadata: { "kind" => "buddy_relay" })

      expect(convo.unread_count).to eq(2)
    end

    it "rides along on the wire payload" do
      landed

      expect(convo.as_wire[:unread_count]).to eq(1)
    end
  end

  describe "#mark_read!" do
    it "clears the count" do
      landed
      convo.mark_read!

      expect(convo.reload.unread_count).to eq(0)
    end

    # It fires on every conversation switch. Going through callbacks would bump
    # updated_at and shuffle the drawer ordering on a plain read.
    it "does not disturb the thread's ordering" do
      landed
      before = convo.reload.updated_at
      convo.mark_read!

      expect(convo.reload.updated_at).to eq(before)
    end

    it "never moves the marker backwards" do
      convo.mark_read!
      marker = convo.reload.last_read_at
      convo.mark_read!(2.hours.ago)

      expect(convo.reload.last_read_at).to eq(marker)
    end
  end

  # What the iOS home-screen badge shows, and what rides on the push.
  describe ".unread_total_for" do
    it "sums every thread the person can see" do
      landed
      other = user.byte_conversations.create!(mode: :claude, name: "Work", last_read_at: 1.hour.ago)
      other.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "x")

      expect(described_class.unread_total_for(user)).to eq(2)
    end

    it "leaves archived threads out of it" do
      landed
      convo.update!(archived: true)

      expect(described_class.unread_total_for(user)).to eq(0)
    end
  end
end
