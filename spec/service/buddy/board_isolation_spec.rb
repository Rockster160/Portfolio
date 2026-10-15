require "rails_helper"

# A board (/board/:id) is a wall surface, not a chat thread. Like the kiosk it
# must never be where an unasked-for message lands — the morning briefing, a
# reminder, a relay — and it must stay out of the chat conversation list.
# Unlike the kiosk it is its own kind, picked out by an explicit flag, because
# the person's own primary thread carries chore groups too and can't be told
# apart by those.
RSpec.describe "Buddy board isolation" do
  let(:user) { create(:user) }

  # The board is the NEWER of the two on purpose: every picker orders by
  # last_message_at, so the board wins on recency the moment it is touched.
  let!(:phone) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: 2.hours.ago)
  }
  let!(:board) {
    user.byte_conversations.create!(
      mode: :buddy, name: "Kitchen", last_message_at: 1.minute.ago, metadata: { "board" => true },
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  it "is caught by the board scopes and kept out of not_board" do
    expect(board.board?).to be(true)
    expect(user.byte_conversations.board).to contain_exactly(board)
    expect(user.byte_conversations.not_board).to contain_exactly(phone)
  end

  describe "where an unasked-for message goes" do
    it "picks the person's thread even when the board is newer" do
      expect(ByteConversation.for_self_initiated(user)).to eq(phone)
    end

    it "is never primary, and a board-only account has nowhere unasked-for to land" do
      phone.destroy!

      expect(ByteConversation.primary_for(user)).to be_nil
      expect(ByteConversation.for_self_initiated(user)).to be_nil
    end
  end

  it "keeps the morning briefing on the person's thread, not the board" do
    expect(Buddy::TodaySchedule.ensure!(user).byte_conversation).to eq(phone)
  end
end
