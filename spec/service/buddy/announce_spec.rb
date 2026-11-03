require "rails_helper"

# Telling somebody in the house something, in their own companion's voice, from
# the console. The alternative is writing it yourself and pasting it in, which
# arrives sounding like nobody they've been talking to.
RSpec.describe Buddy::Announce do
  # User.eve and User.chelsea are `find_by(id:)` on fixed ids, memoized in class
  # variables. Neither exists in the test database, so they're made here with
  # the ids the app looks for and the memo cleared.
  # `first_name` is derived from the id, so the id is the whole identity here.
  def person!(id, username)
    User.find_by(id: id) || create(:user, id: id, username: username)
  end

  let!(:eve) {
    User.class_variable_set(:@@eve, nil)
    person!(4, "Eve")
  }
  let!(:chelsea) {
    User.class_variable_set(:@@chelsea, nil)
    person!(58_128, "Alchemibluum")
  }
  let!(:convo) { eve.byte_conversations.create!(mode: :buddy, name: "Suki", last_message_at: Time.current) }

  let(:out)   { StringIO.new }
  let(:draft) { "Ooh, the reminders panel can edit recurrence now!" }

  def keys(*answers) = StringIO.new(answers.join("\n") + "\n")

  # A queue rather than `and_return(a, b)`: every attempt builds a fresh
  # Buddy::GPT::Client, and any_instance_of sequences per instance, so each new
  # client would hand back the first reply forever.
  def stub_model(*texts)
    queue = texts.dup
    allow_any_instance_of(Buddy::GPT::Client).to receive(:stream) {
      { ok: true, text: (queue.length > 1 ? queue.shift : queue.first) }
    }
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(Buddy::CompanionDelivery).to receive(:notify)
    stub_model(draft)
  end

  describe "who it can reach" do
    it "takes the shorthand people actually type, or a bare username" do
      expect(described_class.resolve(:me)).to eq(User.me)
      expect(described_class.resolve(:rocco)).to eq(User.me)
      expect(described_class.resolve(:chels)).to eq(User.chelsea)
      expect(described_class.resolve(:chelsea)).to eq(User.chelsea)
      expect(described_class.resolve(:eve)).to eq(User.eve)
      expect(described_class.resolve(:mom)).to eq(User.eve)
      expect(described_class.resolve("Eve")).to eq(User.eve)
      expect(described_class.resolve("eve")).to eq(User.eve)
    end
  end

  describe "the draft" do
    it "shows it before anything is sent" do
      described_class.call(:eve, "Reminders can edit recurrence", io: out, input: keys("q"))

      expect(out.string).to include(draft)
      expect(eve.byte_messages.where(body: draft)).to be_empty
    end

    # The mood marker steers the pet's face during a live turn. This isn't one,
    # and leaving it in would ship `[[mood:happy]]` to a lock screen.
    it "strips the mood marker" do
      stub_model("[[mood:happy]] Ooh, big news!")

      described_class.call(:eve, "anything", io: out, input: keys("q"))

      expect(out.string).to include("Ooh, big news!")
      expect(out.string).not_to include("[[mood:")
    end

    it "writes in that person's companion's voice, not a generic one" do
      expect_any_instance_of(Buddy::GPT::Client).to receive(:stream) { |_c, kwargs|
        expect(kwargs[:instructions]).to include("Suki")
        { ok: true, text: draft }
      }

      described_class.call(:eve, "anything", io: out, input: keys("q"))
    end
  end

  it "delivers the draft into their thread on s" do
    described_class.call(:eve, "anything", io: out, input: keys("s"))

    message = convo.reload.byte_messages.last
    expect(message.body).to eq(draft)
    expect(message).to be_inbound
    expect(message.metadata["source"]).to eq("announce")
  end

  # The other door: you already have the words, so nothing is drafted, shown,
  # or confirmed.
  describe "saying it yourself" do
    it "sends the text as written, with no model in the middle, and hands back the message" do
      expect_any_instance_of(Buddy::GPT::Client).not_to receive(:stream)

      returned = described_class.say(:eve, "Server's down for an hour.", io: out)

      message = convo.reload.byte_messages.last
      expect(returned).to eq(message)
      expect(message.body).to eq("Server's down for an hour.")
      expect(message).to be_inbound
      expect(message.metadata["source"]).to eq("announce")
    end

    it "writes into their newest live thread, not an archived one" do
      convo.update!(archived: true)
      current = eve.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      described_class.say(:eve, "anything", io: out)

      expect(current.reload.byte_messages.last.body).to eq("anything")
    end

    it "sends nothing for blank text or somebody it doesn't know" do
      described_class.say(:eve, "   ", io: out)
      described_class.say(:nobody, "hi", io: out)

      expect(convo.reload.byte_messages).to be_empty
    end
  end

  describe "iterating" do
    it "regenerates on r and sends the second draft" do
      stub_model(draft, "Second go, shorter.")

      described_class.call(:eve, "anything", io: out, input: keys("r", "s"))

      expect(convo.reload.byte_messages.last.body).to eq("Second go, shorter.")
    end

    it "folds a note into the next attempt" do
      stub_model(draft, "Shorter version.")
      seeds = []
      allow_any_instance_of(Buddy::GPT::Client).to receive(:stream) { |_c, kwargs|
        seeds << kwargs[:input].first[:content].first[:text]
        { ok: true, text: seeds.length == 1 ? draft : "Shorter version." }
      }

      described_class.call(:eve, "anything", io: out, input: keys("n", "make it shorter", "s"))

      expect(seeds.last).to include("make it shorter")
      expect(convo.reload.byte_messages.last.body).to eq("Shorter version.")
    end

    it "keeps stacking notes across attempts" do
      seeds = []
      allow_any_instance_of(Buddy::GPT::Client).to receive(:stream) { |_c, kwargs|
        seeds << kwargs[:input].first[:content].first[:text]
        { ok: true, text: draft }
      }

      described_class.call(:eve, "x", io: out, input: keys("n", "shorter", "n", "warmer", "q"))

      expect(seeds.last).to include("shorter; warmer")
    end

    # Fat-fingering the prompt should cost a model call, not an unwanted send.
    it "regenerates rather than sending on an answer it doesn't recognise" do
      described_class.call(:eve, "anything", io: out, input: keys("wat", "q"))

      expect(convo.reload.byte_messages).to be_empty
    end
  end

  describe "when the model fails" do
    it "sends nothing" do
      allow_any_instance_of(Buddy::GPT::Client).to receive(:stream).and_raise("boom")

      described_class.call(:eve, "anything", io: out, input: keys("q"))

      expect(convo.reload.byte_messages).to be_empty
    end
  end
end
