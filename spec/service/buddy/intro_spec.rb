require "rails_helper"

# Rocco, 7 Oct 2026: "Each time a user starts a new Buddy conversation, the
# Buddy should introduce themselves. That's also where they can go over the
# features they can help with and such."
#
# A seed rather than a canned paragraph, for the same reason the Today briefing
# is one: it comes out in the thread's own pet's voice, and there is one of it
# instead of five that drift.
RSpec.describe Buddy::Intro do
  let(:user)  { create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    # spec/support/buddy_intro.rb answers "did nothing" for the whole suite so
    # no unrelated example dispatches a turn. This is the file that means it.
    allow(described_class).to receive(:start!).and_call_original
    BuddyDeliverWorker.clear
  end

  around { |example| Sidekiq::Testing.fake! { example.run } }

  describe "the ground it may offer" do
    it "names only what this person actually holds" do
      user.update!(buddy_features: %i[chores lists])
      seed = described_class.seed(user)

      expect(seed).to include("chores, completions, and pebbles", "lists")
      expect(seed).not_to include("the calendar and agenda")
    end

    # The tool layer refuses a feature they don't hold, so offering one in the
    # first message is a promise broken the first time they take it up.
    it "keeps the owner's own features out of a member's introduction" do
      user.update!(buddy_features: Buddy::Features.all)

      expect(described_class.seed(user)).not_to include("commands on the Mac")
    end

    # Buddy::Features::CORE is never withheld, so it is never in the list the
    # gate produces - it has to be said here or it goes unsaid.
    it "still offers the things nobody is ever without" do
      user.update!(buddy_features: [])
      seed = described_class.seed(user)

      expect(seed).to include("timers and alarms", "the weather")
    end

    # It is a hello. The one thing it must not turn into is the settings page.
    it "asks for prose rather than a feature list" do
      expect(described_class.seed(user)).to include("no bulleted list of features")
    end
  end

  describe "starting one" do
    it "posts a hidden seed and hands it to the ordinary turn" do
      seed = described_class.start!(convo)

      expect(seed).to have_attributes(direction: "outbound", state: "pending")
      expect(seed.metadata).to include("kind" => "buddy_trigger", "hidden" => true)
      expect(seed.metadata["buddy_action"]).to eq("intro")
      expect(BuddyDeliverWorker.jobs.map { |j| j["args"] }).to eq([[seed.id]])
    end

    # The seed is hidden, so the thread would otherwise sit blank for the whole
    # round trip with nothing on screen saying anything is coming.
    it "puts the pet in its thinking pose while it writes" do
      expect(Buddy::ExpressionState).to receive(:transition!).with(convo, :turn_started)

      described_class.start!(convo)
    end

    it "says nothing in a thread somebody has already spoken in" do
      convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hi")

      expect(described_class.start!(convo)).to be_nil
      expect(BuddyDeliverWorker.jobs).to be_empty
    end

    it "leaves every other kind of thread alone" do
      claude = ByteConversation.create!(user: user, mode: :claude)

      expect(described_class.start!(claude)).to be_nil
    end
  end

  # A turn nobody started, which is what `buddy_trigger` means - so the
  # sentiment reading is told so, and the history replays it as what it was.
  describe "what later turns see of it" do
    it "stands in as the thread opening rather than as a tap or a notification" do
      seed = described_class.start!(convo)

      expect(Buddy::GPT::History.seed_standin(seed.metadata, seed.body))
        .to eq("[opened a new thread - this is you introducing yourself]")
    end
  end
end
