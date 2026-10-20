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

  describe "a dream's face" do
    def dream!(expression: nil, groups: ["Whisper"], strength: nil)
      Buddy::Alerts.hold!(
        user: user, key: "food-#{SecureRandom.hex(3)}", body: "Foodies!",
        groups: groups, expression: expression, dream: true, conversation: board, strength: strength,
      )
    end

    before { board.update!(buddy_expression: "neutral") }

    it "thinks over an idle mood" do
      dream!

      expect(described_class.for(board)).to eq("thinking")
    end

    it "wears the face the dream names" do
      dream!(expression: "eager")

      expect(described_class.for(board)).to eq("eager")
    end

    it "gives way to any real mood" do
      dream!
      board.update!(buddy_expression: "happy")

      expect(described_class.for(board)).to eq("happy")
    end

    it "gives way to a held face, and is no alert face itself" do
      dream!(expression: "eager")
      expect(described_class.held(board)).to be_nil

      alert!(groups: ["Whisper"], expression: "pounce")
      expect(described_class.for(board)).to eq("pounce")
    end

    it "beats a real mood when raised stronger than one, but not Whisper's state" do
      dream!(expression: "eager", strength: 45)
      board.update!(buddy_expression: "happy")
      expect(described_class.for(board)).to eq("eager")

      described_class.record_whisper!(user, { status: "Gone 👋", groups: ["Whisper"] })
      expect(described_class.for(board)).to eq("hiding")
    end

    it "ignores a dream aimed at another group" do
      dream!(groups: ["Garage"])

      expect(described_class.for(board)).to eq("neutral")
    end

    it "puts away a dream raised before the pet was tapped, until a newer one" do
      dream!(expression: "eager")
      board.update!(metadata: board.metadata.merge("dream_dismissed_at" => 1.second.from_now.iso8601(3)))

      expect(described_class.dream_face(board)).to be_nil

      travel(1.minute) { dream!(expression: "eager") }
      expect(described_class.dream_face(board)).to eq("eager")
    end

    it "thinks over a hot chore the board is dreaming of" do
      expect(described_class.showing(board, chore_dream: true)).to eq("thinking")
      expect(described_class.showing(board)).to be_nil
    end
  end

  describe "an alert's strength" do
    def strong_alert!(expression:, strength:)
      Buddy::Alerts.hold!(
        user: user, key: "gate-#{SecureRandom.hex(3)}", body: "Gate open",
        groups: ["Whisper"], expression: expression, strength: strength, conversation: board,
      )
    end

    it "gives way to a real mood when raised weaker than one" do
      strong_alert!(expression: "pounce", strength: 20)

      expect(described_class.for(board)).to eq("happy")
    end

    it "shows the strongest of several alerts, and beats Whisper's state when raised above it" do
      strong_alert!(expression: "pounce", strength: 55)
      strong_alert!(expression: "eager", strength: 80)
      described_class.record_whisper!(user, { status: "Napping", groups: ["Whisper"] })

      expect(described_class.for(board)).to eq("eager")
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
