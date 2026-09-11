require "rails_helper"

# The quick-action chips seed a Buddy turn with a prompt written in the first
# person, and the same prompt went to whoever tapped it. Not everyone in the
# house has chores: `get_context` doesn't offer them `chores_pending_today`, so
# the seed was sending their companion after a section that won't answer, and
# teaching it - in their own voice - to talk about a part of the app they have
# no access to. Prod 5312, Eve's thread.
RSpec.describe Buddy::QuickActionsController, type: :controller do
  let(:user) { User.me }
  let(:conversation) { user.byte_conversations.create!(mode: :buddy) }

  def without_chores!
    allow(Buddy::Features).to receive(:enabled?).and_call_original
    allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(false)
  end

  def seed(kind, **params)
    post(:create, params: { kind: kind, conversation_id: conversation.id, **params })
    conversation.byte_messages.where("metadata ->> 'kind' = ?", "buddy_trigger").last&.body.to_s
  end

  before do
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    allow(BuddyDeliverWorker).to receive(:perform_async)
    sign_in user
  end

  describe "what a person without chores is sent after" do
    before { without_chores! }

    it "keeps the chore sections out of What now?" do
      body = seed("suggest")

      expect(body).not_to include("chores_pending_today", "chores_done_today", "chores_hot_picks")
      expect(body).to include("today_agenda", "stashed_ideas")
    end

    it "still tells it where to look, rather than leaving the list empty" do
      expect(seed("suggest")).to match(/WHERE TO LOOK.*1\. `today_agenda`/m)
    end

    # Written as the owner's own habit and sent to everybody.
    it "drops the owner's late-evening chore habit" do
      expect(seed("suggest")).not_to include("9 and 11 PM")
    end

    it "keeps them out of the affirmation's reading list" do
      expect(seed("affirmation")).not_to include("chores_done_today")
    end

    it "drops the chore clause from the tone note" do
      expect(seed("affirmation")).not_to include("recite chores")
      expect(seed("affirmation")).to include("Warm, short, human")
    end

    it "leaves the Home bucket pointing at ideas instead of a chore fallback" do
      expect(seed("suggest", category: "home")).not_to include("household chore from")
    end
  end

  describe "what the owner is sent after" do
    it "still leads What now? with the pending chores" do
      body = seed("suggest")

      expect(body).to include("chores_pending_today", "chores_hot_picks")
      expect(body).to match(/WHERE TO LOOK.*1\. `chores_pending_today`/m)
    end

    it "still reads the done ones for an affirmation" do
      expect(seed("affirmation")).to include("chores_done_today")
    end

    it "still carries the chore clause in the tone note" do
      expect(seed("affirmation")).to include("recite chores")
    end

    it "still offers a chore as the Home fallback" do
      expect(seed("suggest", category: "home")).to include("household chore from `chores_pending_today`")
    end
  end
end
