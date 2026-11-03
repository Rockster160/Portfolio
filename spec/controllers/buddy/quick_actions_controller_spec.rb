require "rails_helper"

# The quick-action chips seed a Buddy turn with a prompt that names the context
# sections to read. A person without chores is never sent after the chore
# sections, since `get_context` won't offer them.
RSpec.describe Buddy::QuickActionsController, type: :controller do
  let(:user) { User.me }
  let(:conversation) { user.byte_conversations.create!(mode: :buddy) }

  def seed(kind, **params)
    post(:create, params: { kind: kind, conversation_id: conversation.id, **params })
    conversation.byte_messages.where("metadata ->> 'kind' = ?", "buddy_trigger").last&.body.to_s
  end

  before do
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    allow(BuddyDeliverWorker).to receive(:perform_async)
    sign_in user
  end

  it "keeps the chore sections out of the seeds for a person without chores", :aggregate_failures do
    allow(Buddy::Features).to receive(:enabled?).and_call_original
    allow(Buddy::Features).to receive(:enabled?).with(user, :chores).and_return(false)

    suggest = seed("suggest")
    expect(suggest).not_to include("chores_pending_today", "chores_done_today", "chores_hot_picks")
    expect(suggest).to match(/1\. `today_agenda`/)
    expect(suggest).to include("stashed_ideas")
    expect(seed("affirmation")).not_to include("chores_done_today")
    expect(seed("suggest", category: "home")).not_to include("chores_pending_today")
  end

  it "leads the owner's seeds with the chore sections", :aggregate_failures do
    suggest = seed("suggest")
    expect(suggest).to include("chores_hot_picks")
    expect(suggest).to match(/1\. `chores_pending_today`/)
    expect(seed("affirmation")).to include("chores_done_today")
    expect(seed("suggest", category: "home")).to include("chores_pending_today")
  end
end
