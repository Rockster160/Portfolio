require "rails_helper"

RSpec.describe Buddy::BoardFace do
  let(:user) { User.me }
  let!(:board) {
    user.byte_conversations.create!(
      mode: :buddy, name: "Whisper", last_message_at: Time.current, buddy_expression: "happy",
      metadata: { "board" => true, "chore_tags" => ["Whisper"] },
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def alert!(groups:, expression:)
    BuddyAlert.create!(
      user: user, byte_conversation: board, key: "gate-#{SecureRandom.hex(3)}", body: "Gate open",
      raised_at: Time.current, last_raised_at: Time.current,
      metadata: { "groups" => groups, "expression" => expression },
    )
  end

  describe ".for" do
    it "is the mood when nothing is held" do
      expect(described_class.for(board)).to eq("happy")
    end

    it "is an alert's face when the alert is aimed at the board" do
      alert!(groups: ["whisper"], expression: "pounce")

      expect(described_class.for(board)).to eq("pounce")
    end

    it "ignores an alert aimed at another group" do
      alert!(groups: ["Garage"], expression: "pounce")

      expect(described_class.for(board)).to eq("happy")
    end

    it "puts Whisper's state over an alert's face" do
      alert!(groups: ["Whisper"], expression: "pounce")
      described_class.record_whisper!(user, { status: "Napping 💤", groups: "Whisper" })

      expect(described_class.whisper_state(board)).to eq(:asleep)
      expect(described_class.for(board)).to eq("sleeping")
    end

    it "lets go once Whisper is awake again" do
      described_class.record_whisper!(user, { status: "Gone 👋", groups: ["Whisper"] })
      expect(described_class.for(board)).to eq("hiding")

      described_class.record_whisper!(user, { status: "Awake ☀️" })
      expect(described_class.for(board)).to eq("happy")
    end
  end

  describe ".record_whisper!" do
    it "tells the board's viewers its face only when the state moved" do
      described_class.record_whisper!(user, { status: "Napping", groups: ["Whisper"] })
      described_class.record_whisper!(user, { status: "Napping", groups: ["Whisper"] })

      expect(MonitorChannel).to have_received(:broadcast_to).with(
        user,
        hash_including(data: hash_including(kind: :board_face, conversation_id: board.id, expression: "sleeping")),
      ).once
    end

    it "keeps nothing from a broadcast with no status or groups" do
      described_class.record_whisper!(user, { sound: "wake" })

      expect(user.caches.get(described_class::WHISPER_CACHE)).to eq({})
    end
  end

  describe "the Whisper monitor broadcast" do
    it "records the feed's status for the boards" do
      Jil::Executor.call(user,
        <<~'JIL',
          h = Hash.new({
            c = Keyval.new("status", "🛏️ Sleeping")::Keyval
            d = Keyval.new("groups", "Whisper")::Keyval
          })::Hash
          a = Monitor.broadcast("whisper-durations", {
            b = MonitorData.data(h)::MonitorData
          }, false)::Monitor
        JIL
      )

      expect(described_class.whisper_state(board)).to eq(:asleep)
    end
  end
end
