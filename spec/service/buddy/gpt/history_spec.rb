require "rails_helper"

RSpec.describe Buddy::GPT::History do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  def said(body, direction: :outbound, kind: nil, state: :delivered, source: nil, peer: nil)
    meta = {}
    meta["kind"]        = kind if kind
    meta["source"]      = source if source
    meta["relay_peer"]  = { "name" => peer } if peer
    convo.byte_messages.create!(
      user: user, direction: direction, state: state, body: body, metadata: meta,
    )
  end

  def build(upto: nil)
    described_class.build(convo, upto: upto)
  end

  describe "roles" do
    it "maps the person's messages to user and Buddy's replies to assistant" do
      said("morning")
      said("Morning!", direction: :inbound, kind: "buddy")

      expect(build).to eq([
        { role: :user, content: "morning" },
        { role: :assistant, content: "Morning!" },
      ])
    end

    it "includes hidden seed prompts, which are how Buddy gets told to speak up" do
      said("[scheduled prompt] Rocco just added an event, give her a heads-up", kind: "buddy_trigger")

      expect(build.first[:role]).to eq(:user)
      expect(build.first[:content]).to include("just added an event")
    end
  end

  describe "exclusions" do
    it "leaves out receipt chips so Buddy does not learn to narrate receipts" do
      said("Marked the dishes done ✓", direction: :inbound, kind: "buddy_activity")

      expect(build).to be_empty
    end

    it "leaves out system and action-request messages" do
      said("cleared Claude session", direction: :inbound, kind: "system")
      said("Approve Bash?", direction: :inbound, kind: "action-request")

      expect(build).to be_empty
    end

    it "leaves out a half-written streaming reply" do
      said("I was saying someth", direction: :inbound, kind: "buddy", state: :streaming)

      expect(build).to be_empty
    end

    it "leaves out a failed reply" do
      said("buddy error: boom", direction: :inbound, kind: "buddy", state: :failed)

      expect(build).to be_empty
    end

    it "leaves out blank bodies" do
      said("   ", direction: :inbound, kind: "buddy")

      expect(build).to be_empty
    end
  end

  describe "bridged relay messages" do
    it "includes a message received from the partner, attributed" do
      said("I fed the dog", direction: :inbound, kind: "buddy_relay", source: "relay", peer: "Byte")

      expect(build).to eq([
        { role: :assistant, content: "[relayed to you from Byte] I fed the dog" },
      ])
    end

    it "includes the sender-side copy with outgoing framing" do
      said("running late", direction: :inbound, kind: "buddy_relay", source: "relay_copy", peer: "Moss")

      expect(build.first[:content]).to eq("[you passed this along to Moss] running late")
    end

    it "falls back to a neutral label when the peer identity is missing" do
      said("hi", direction: :inbound, kind: "buddy_relay", source: "relay")

      expect(build.first[:content]).to include("their companion")
    end

    it "keeps a bare answer next to the question it answers" do
      # The regression this exists for: with relays excluded, Buddy saw only
      # "tacos" and had nothing to attach it to.
      said("What do you want for dinner?", direction: :inbound, kind: "buddy_relay", source: "relay", peer: "Byte")
      said("tacos")

      expect(build.pluck(:role)).to eq([:assistant, :user])
      expect(build.first[:content]).to include("What do you want for dinner?")
    end
  end

  describe "compaction boundary" do
    it "starts after buddy_recap_at so a compacted stretch is not replayed" do
      said("ancient history")
      convo.update!(metadata: { "buddy_recap_at" => Time.current.iso8601(6) })
      said("after the compact")

      expect(build.pluck(:content)).to eq(["after the compact"])
    end

    it "ignores an unparseable recap timestamp rather than dropping everything" do
      said("still here")
      convo.update!(metadata: { "buddy_recap_at" => "not a time" })

      expect(build.pluck(:content)).to eq(["still here"])
    end
  end

  describe "upto" do
    it "stops at the message being answered" do
      first = said("one")
      said("two")

      expect(build(upto: first).pluck(:content)).to eq(["one"])
    end
  end

  describe "safety cap" do
    it "keeps the most recent messages when a thread runs long" do
      (described_class::MAX_MESSAGES + 10).times { |i| said("msg #{i}") }

      items = build
      expect(items.length).to eq(described_class::MAX_MESSAGES)
      expect(items.last[:content]).to eq("msg #{described_class::MAX_MESSAGES + 9}")
    end
  end
end
