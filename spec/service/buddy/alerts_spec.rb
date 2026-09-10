require "rails_helper"

# A message that stands for something OUTSTANDING, and stops standing for it
# when the thing is dealt with. The whole point is that ONE bubble carries the
# condition from noticed to handled — a second message an hour later saying the
# same thing is what this exists to not do.
RSpec.describe Buddy::Alerts do
  let(:user) { create(:user) }
  let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def frames
    captured = []
    allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| captured << payload }
    captured
  end

  describe "raising one" do
    it "posts a bubble, pushes, and holds the condition open" do
      alert = described_class.raise!(user: user, key: "gate", body: "The gate is open")

      expect(alert).to be_status_open
      expect(alert.raised_count).to eq(1)
      message = alert.byte_message
      expect(message.body).to eq("The gate is open")
      expect(message.metadata["kind"]).to eq("alert")
      expect(message.metadata.dig("alert", "key")).to eq("gate")
      expect(message.metadata.dig("alert", "status")).to eq("open")
      expect(WebPushNotifications).to have_received(:send_to_byte).once
    end

    it "refuses without a key, without words, or without a thread to say it in" do
      expect(described_class.raise!(user: user, key: "  ", body: "words")).to be_nil
      expect(described_class.raise!(user: user, key: "gate", body: "  ")).to be_nil

      allow(Buddy::CompanionRelay).to receive(:conversation_for).and_return(nil)
      expect(described_class.raise!(user: user, key: "gate", body: "words")).to be_nil
      expect(ByteMessage.count).to eq(0)
    end
  end

  describe "the same condition, seen again" do
    before { described_class.raise!(user: user, key: "gate", body: "The gate is open") }

    it "rewrites the one bubble instead of posting another" do
      expect { described_class.raise!(user: user, key: "gate", body: "The gate is still open") }
        .not_to change(ByteMessage, :count)

      alert = BuddyAlert.open_for(user, "gate")
      expect(alert.raised_count).to eq(2)
      expect(alert.byte_message.reload.body).to eq("The gate is still open")
      expect(alert.byte_message.metadata.dig("alert", "count")).to eq(2)
    end

    # They were told when it opened and the bubble has said so ever since. A
    # count on the record is what keeps the recurrence from being invisible.
    it "does not buzz again for something already on screen" do
      described_class.raise!(user: user, key: "gate", body: "The gate is open")

      expect(WebPushNotifications).to have_received(:send_to_byte).once
    end

    it "tells the client this is the same message moving, not a new one" do
      captured = frames
      described_class.raise!(user: user, key: "gate", body: "The gate is open")

      repaint = captured.select { |f| f.dig(:data, :kind) == :message }.last
      expect(repaint.dig(:data, :update)).to be(true)
    end

    it "keeps a different key entirely separate" do
      expect { described_class.raise!(user: user, key: "garage", body: "Garage is open") }
        .to change(ByteMessage, :count).by(1)
      expect(BuddyAlert.status_open.count).to eq(2)
    end
  end

  describe "resolving one" do
    before { described_class.raise!(user: user, key: "gate", body: "The gate is open") }

    it "rewrites the bubble it already owns rather than adding a second" do
      expect { described_class.resolve!(user: user, key: "gate", body: "Gate is shut") }
        .not_to change(ByteMessage, :count)

      alert = BuddyAlert.for_key("gate").first
      expect(alert).to be_status_resolved
      expect(alert.resolved_at).to be_present
      expect(alert.byte_message.reload.body).to eq("Gate is shut")
      expect(alert.byte_message.metadata.dig("alert", "status")).to eq("resolved")
    end

    it "keeps its own words when the resolve brings none" do
      described_class.resolve!(user: user, key: "gate")

      expect(ByteMessage.last.body).to eq("The gate is open")
      expect(ByteMessage.last.metadata.dig("alert", "status")).to eq("resolved")
    end

    it "clears in silence - the good news is on the bubble, not on the lock screen" do
      described_class.resolve!(user: user, key: "gate")

      expect(WebPushNotifications).to have_received(:send_to_byte).once
    end

    # How a check that runs on a schedule tells "I just cleared something" from
    # "it was already fine", without keeping track itself.
    it "answers nil when nothing was open under that key" do
      described_class.resolve!(user: user, key: "gate")

      expect(described_class.resolve!(user: user, key: "gate")).to be_nil
      expect(described_class.resolve!(user: user, key: "never-raised")).to be_nil
    end

    it "opens a fresh one, with its own bubble, if the condition comes back" do
      described_class.resolve!(user: user, key: "gate")

      expect { described_class.raise!(user: user, key: "gate", body: "Open again") }
        .to change(ByteMessage, :count).by(1)
      expect(BuddyAlert.for_key("gate").count).to eq(2)
      expect(BuddyAlert.open_for(user, "gate").raised_count).to eq(1)
    end
  end

  it "refuses a second open one under the same key" do
    described_class.raise!(user: user, key: "gate", body: "The gate is open")

    duplicate = BuddyAlert.new(
      user: user, byte_conversation: conversation, key: "gate", body: "again",
      status: :open, raised_at: Time.current, last_raised_at: Time.current
    )

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # Words in the thread the person can see and will ask about. Left out of
  # history, the honest answer to "what was that about the gate?" is that no
  # such message exists - the same blindness the relay bridges had.
  it "is replayed to the model as something Buddy said" do
    described_class.raise!(user: user, key: "gate", body: "The gate is open")

    history = Buddy::GPT::History.build(conversation, upto: nil)

    expect(history.to_json).to include("The gate is open")
  end

  # An alert nobody deals with is worse than one nobody sees: while it stands
  # open it owns its key, so every later occurrence lands on the same buried
  # bubble instead of announcing itself.
  describe "letting go of one" do
    let!(:alert) { described_class.raise!(user: user, key: "gate", body: "The gate is open") }

    it "closes it without claiming the condition cleared" do
      described_class.dismiss!(user: user, id: alert.id)

      expect(alert.reload).to be_status_dismissed
      expect(alert.resolution).to be_nil
      expect(alert.byte_message.reload.metadata.dig("alert", "status")).to eq("dismissed")
    end

    it "frees the key, so the next occurrence opens fresh and buzzes again" do
      described_class.dismiss!(user: user, id: alert.id)

      expect { described_class.raise!(user: user, key: "gate", body: "Open again") }
        .to change(ByteMessage, :count).by(1)
      expect(WebPushNotifications).to have_received(:send_to_byte).twice
    end

    it "reaches nothing that isn't theirs and still open" do
      expect(described_class.dismiss!(user: create(:user), id: alert.id)).to be_nil
      described_class.resolve!(user: user, key: "gate")
      expect(described_class.dismiss!(user: user, id: alert.id)).to be_nil
    end
  end

  describe "what is still standing" do
    it "lists every open one, oldest first, with where its words are" do
      first  = described_class.raise!(user: user, key: "gate", body: "The gate is open")
      second = described_class.raise!(user: user, key: "garage", body: "Garage is open")

      wire = described_class.outstanding_wire(user)

      expect(wire.pluck("key")).to eq(%w[gate garage])
      expect(wire.first["body"]).to eq("The gate is open")
      expect(wire.first["message_id"]).to eq(first.byte_message_id)
      expect(wire.last["conversation_id"]).to eq(second.byte_conversation_id)
    end

    it "drops one the moment it stops being open" do
      described_class.raise!(user: user, key: "gate", body: "The gate is open")
      described_class.resolve!(user: user, key: "gate")

      expect(described_class.outstanding_wire(user)).to be_empty
    end

    it "tells every open surface each time the list changes" do
      captured = frames
      described_class.raise!(user: user, key: "gate", body: "The gate is open")
      described_class.resolve!(user: user, key: "gate")

      strip = captured.select { |f| f.dig(:data, :kind) == :alerts }
      expect(strip.length).to eq(2)
      expect(strip.first.dig(:data, :alerts).length).to eq(1)
      expect(strip.last.dig(:data, :alerts)).to be_empty
    end
  end

  # A repeat while the bubble is fresh is something they were told about
  # minutes ago. A repeat a day later has outlived their memory of it, and going
  # on silently is how one ignored alert eats every occurrence after it.
  describe "a condition that has been standing a long time" do
    it "buzzes again once the last one has aged out" do
      described_class.raise!(user: user, key: "gate", body: "The gate is open")

      travel_to(BuddyAlert::PUSH_AGAIN_AFTER.from_now + 1.minute) do
        described_class.raise!(user: user, key: "gate", body: "The gate is STILL open")
      end

      expect(WebPushNotifications).to have_received(:send_to_byte).twice
      # Still one bubble. The buzz is about the occurrence; the bubble is the
      # condition, and there is only ever one of those.
      expect(ByteMessage.count).to eq(1)
      expect(BuddyAlert.open_for(user, "gate").raised_count).to eq(2)
    end

    it "stays quiet for a repeat inside the window" do
      described_class.raise!(user: user, key: "gate", body: "The gate is open")

      travel_to(1.hour.from_now) do
        described_class.raise!(user: user, key: "gate", body: "The gate is open")
      end

      expect(WebPushNotifications).to have_received(:send_to_byte).once
    end
  end

  # The bubble can be deleted from the thread. An alert outliving its message is
  # a lot better than a resolve that raises.
  it "resolves without its bubble rather than blowing up" do
    described_class.raise!(user: user, key: "gate", body: "The gate is open")
    ByteMessage.last.destroy!

    expect { described_class.resolve!(user: user, key: "gate") }.not_to raise_error
    expect(BuddyAlert.for_key("gate").first).to be_status_resolved
  end
end
