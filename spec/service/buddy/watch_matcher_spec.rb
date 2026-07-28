require "rails_helper"

# BuddyWatch = condition-based reminder. WatchMatcher is called from the
# single Jil::Executor.trigger chokepoint for every trigger the platform
# fires, matches active watches for the user against the payload, and
# delivers through Buddy::CompanionDelivery.
RSpec.describe Buddy::WatchMatcher do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    # Stub the delivery layer: the real prompt path spawns a Mac round-trip
    # thread, which deadlocks against transactional fixtures. WatchMatcher's
    # own contract is "which watch fires + how state advances"; delivery is
    # CompanionDelivery's concern (covered via the reminder path).
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
    allow(Buddy::CompanionDelivery).to receive(:deliver_plain)
  end

  def make_watch(attrs = {})
    BuddyWatch.create!({
      user:              user,
      byte_conversation: convo,
      kind:              "prompt",
      body:              "floss",
      trigger_scope:     "chore_completion",
      match:             { "action" => "completed", "chore_name" => "Brush Teeth" },
    }.merge(attrs))
  end

  describe "#matches?" do
    it "requires every match key, case-insensitive, indifferent keys, substring ok" do
      w = make_watch
      expect(w.matches?("action" => "completed", "chore_name" => "Brush Teeth")).to be(true)
      expect(w.matches?(action: "completed", chore_name: "brush teeth")).to be(true)
      expect(w.matches?("action" => "completed", "chore_name" => "Dishes")).to be(false)
      expect(w.matches?("action" => "uncompleted", "chore_name" => "Brush Teeth")).to be(false)
    end

    it "treats an empty match as 'any payload' (deploy)" do
      w = make_watch(trigger_scope: "deploy", match: {})
      expect(w.matches?("sha" => "abc123")).to be(true)
    end
  end

  describe ".dispatch" do
    it "fires a matching one-shot watch, seeds an in-character turn, marks it terminal" do
      w = make_watch
      described_class.dispatch(user, "chore_completion", { "action" => "completed", "chore_name" => "Brush Teeth" })

      expect(w.reload.fired_at).to be_present
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(
        hash_including(seed: "floss", metadata: hash_including(source: "watch", watch_id: w.id)),
      )
    end

    it "does not fire a non-matching watch" do
      w = make_watch
      described_class.dispatch(user, "chore_completion", { "action" => "completed", "chore_name" => "Dishes" })
      expect(w.reload.fired_at).to be_nil
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    end

    it "keeps a repeat watch active after firing (last_fired_at only)" do
      w = make_watch(one_shot: false)
      described_class.dispatch(user, "chore_completion", { "action" => "completed", "chore_name" => "Brush Teeth" })

      w.reload
      expect(w.fired_at).to be_nil
      expect(w.last_fired_at).to be_present
      expect(BuddyWatch.active.where(id: w.id)).to exist
    end

    it "bails on a non-watchable scope without querying watches" do
      make_watch
      expect(BuddyWatch).not_to receive(:active)
      described_class.dispatch(user, "monitor", { "channel" => "uptime" })
    end
  end

  describe "wired into Jil::Executor.trigger" do
    it "fires a deploy watch through the real trigger chokepoint" do
      w = make_watch(trigger_scope: "deploy", match: {}, body: "deploy's live")
      Jil::Executor.trigger(user, :deploy, { "id" => "deploy", "deploy" => "finished", "sha" => "abc" })
      expect(w.reload.fired_at).to be_present
    end
  end
end
