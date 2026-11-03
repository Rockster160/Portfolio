require "rails_helper"

# A new Buddy thread opens with the pet introducing itself: a hidden seed run
# through the ordinary turn, so it comes out in the thread's own voice.
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

  # The tool layer refuses a feature they don't hold, so offering one in the
  # first message is a promise broken the first time they take it up. CORE is
  # never in the gate's list, so it has to be offered here or it goes unsaid.
  it "offers only what this person holds, never the owner's own, and always the core", :aggregate_failures do
    user.update!(buddy_features: %i[chores lists])
    seed = described_class.seed(user)
    expect(seed).to include("chores, completions, and pebbles", "lists")
    expect(seed).not_to include("the calendar and agenda")

    user.update!(buddy_features: Buddy::Features.all)
    expect(described_class.seed(user)).not_to include("commands on the Mac")

    user.update!(buddy_features: [])
    expect(described_class.seed(user)).to include("timers and alarms", "the weather")
  end

  describe "starting one" do
    # The seed is hidden, so without the thinking pose the thread would sit
    # blank for the whole round trip.
    it "posts a hidden seed, hands it to the ordinary turn, and shows the thinking pose", :aggregate_failures do
      expect(Buddy::ExpressionState).to receive(:transition!).with(convo, :turn_started)

      seed = described_class.start!(convo)

      expect(seed).to have_attributes(direction: "outbound", state: "pending")
      expect(seed.metadata).to include("kind" => "buddy_trigger", "hidden" => true)
      expect(seed.metadata["buddy_action"]).to eq("intro")
      expect(BuddyDeliverWorker.jobs.map { |j| j["args"] }).to eq([[seed.id]])
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
end
