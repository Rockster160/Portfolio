require "rails_helper"

RSpec.describe Buddy::BoardFace do
  let(:user) { User.me }
  # Bloom, one of the pets with pounce art. (A new thread takes its owner's
  # pet, so it's set after.)
  let!(:board) {
    user.byte_conversations.create!(
      mode: :buddy, name: "Whisper", last_message_at: Time.current, buddy_expression: "happy",
      metadata: { "board" => true, "chore_tags" => ["Whisper"] },
    ).tap { |convo| convo.update!(buddy_theme: :bloom) }
  }

  # A look with no words, the way Jil's Buddy.mood holds one. This point lands
  # on every pet's sleeping face.
  let(:asleep) { { warmth: 0.55, play: 0.05, weight: 0.2, strain: 0.0, reach: 0.05 } }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def mood!(mood: asleep, groups: ["Whisper"], strength: 60)
    Buddy::Alerts.hold!(
      user: user, key: "mood-#{SecureRandom.hex(3)}", body: nil,
      groups: groups, mood: mood, strength: strength, conversation: board,
    )
  end

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

    it "keeps to the pet's own feelings when it has no drawing for the face named" do
      board.update!(buddy_theme: :byte)
      alert!(groups: ["Whisper"], expression: "pounce")

      expect(described_class.for(board)).to eq("happy")
    end

    it "wears a system face on any pet" do
      board.update!(buddy_theme: :tiko)
      alert!(groups: ["Whisper"], expression: "sleeping")

      expect(described_class.for(board)).to eq("sleeping")
    end

    it "ignores an alert aimed at another group" do
      alert!(groups: ["Garage"], expression: "pounce")

      expect(described_class.for(board)).to eq("happy")
    end

    it "puts a stronger mood over an alert's face" do
      alert!(groups: ["Whisper"], expression: "pounce")
      mood!

      expect(described_class.for(board)).to eq("sleeping")
    end

    it "lets go once the mood is resolved" do
      held = mood!
      expect(described_class.for(board)).to eq("sleeping")

      Buddy::Alerts.resolve!(user: user, key: held.key)
      expect(described_class.for(board)).to eq("happy")
    end

    it "answers a mood with each pet's own face" do
      mood!(mood: { warmth: 0.7, play: 0.5, weight: 0.35, strain: 0.05, reach: 0.1 })

      board.update!(buddy_theme: :tiko)
      expect(described_class.for(board)).to eq("nerd")
      board.update!(buddy_theme: :moss)
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

    it "beats a real mood when raised stronger than one, but not a stronger held mood" do
      dream!(expression: "eager", strength: 45)
      board.update!(buddy_expression: "happy")
      expect(described_class.for(board)).to eq("eager")

      mood!
      expect(described_class.for(board)).to eq("sleeping")
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

    it "shows the strongest of several alerts, and beats a held mood when raised above it" do
      strong_alert!(expression: "pounce", strength: 55)
      strong_alert!(expression: "eager", strength: 80)
      mood!

      expect(described_class.for(board)).to eq("eager")
    end
  end
end
