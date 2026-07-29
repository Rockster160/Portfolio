require "rails_helper"

# Brain-dump capture: arm a bucket, the next message becomes an idea; "anything"
# is sorted by Buddy; ideas resurface in context and can be managed by tools.
RSpec.describe "Buddy brain-dump (stash)" do
  let(:user) { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  def message(body)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
  end

  describe Buddy::Stash do
    it "arms + reads + expires the latch" do
      described_class.arm!(convo, "home")
      expect(described_class.armed_category(convo.reload)).to eq("home")

      convo.update!(metadata: convo.metadata.merge("stash_armed_at" => 20.minutes.ago.iso8601))
      expect(described_class.armed_category(convo.reload)).to be_nil # past TTL
    end

    it "files a concrete-bucket idea, clears the latch, and runs a response turn" do
      described_class.arm!(convo, "work")
      idea = described_class.capture!(user, convo, message("ship the invoice tool"), "work")

      expect(idea).to have_attributes(category: "work", body: "ship the invoice tool", status: "active")
      expect(described_class.armed_category(convo.reload)).to be_nil
      # Buddy responds (acknowledge + offer to talk it through) even for a
      # concrete bucket.
      expect(BuddyDeliverWorker).to have_received(:perform_async)
    end

    it "saves an 'anything' idea unsorted and dispatches Buddy to sort + respond" do
      described_class.arm!(convo, "anything")
      idea = described_class.capture!(user, convo, message("that garage shelf thing"), "anything")

      expect(idea.category).to be_nil
      expect(BuddyDeliverWorker).to have_received(:perform_async)
    end

    it "applies Buddy's sort from a sort_stash call" do
      idea = BuddyIdea.create!(user: user, body: "garage shelves", status: :active)
      Buddy::SideEffects.call(convo, :sort_stash, {
        "id" => idea.id, "category" => "home", "summary" => "build garage shelves",
      })

      expect(idea.reload).to have_attributes(category: "home", summary: "build garage shelves")
    end

    it "refines just the summary from a talk-through (summary-only call)" do
      idea = BuddyIdea.create!(user: user, category: :home, summary: "shelves", body: "garage shelves", status: :active)
      Buddy::SideEffects.call(convo, :sort_stash, {
        "id" => idea.id, "summary" => "floating oak shelves over the bench",
      })

      expect(idea.reload).to have_attributes(category: "home", summary: "floating oak shelves over the bench")
    end
  end

  describe "management tools" do
    let!(:idea) { BuddyIdea.create!(user: user, category: :me, body: "learn rust", status: :active) }

    def run(tool_name, payload)
      tool = Buddy::Tools[tool_name]
      ctx  = Buddy::ToolContext.new(user)
      confirm = tool[:confirm].call(payload, ctx)
      tool[:execute].call(payload.merge(confirm[:resolved] || {}), Buddy::ToolContext.new(user))
    end

    it "move_idea refiles the bucket" do
      run(:move_idea, { id: idea.id, category: :work })
      expect(idea.reload.category).to eq("work")
    end

    it "defer_idea sets a remind_after and defers it" do
      run(:defer_idea, { id: idea.id })
      expect(idea.reload).to have_attributes(status: "deferred")
      expect(idea.remind_after).to be_present
    end

    it "drop_idea forgets it" do
      run(:drop_idea, { id: idea.id })
      expect(idea.reload.status).to eq("dropped")
    end
  end

  it "surfaces surfaceable ideas in context, hiding dropped + not-yet-due defers" do
    live = BuddyIdea.create!(user: user, category: :home, body: "fix the gate", summary: "fix the gate", status: :active)
    BuddyIdea.create!(user: user, category: :me, body: "gone", status: :dropped)
    BuddyIdea.create!(user: user, category: :work, body: "later", status: :deferred, remind_after: 3.days.from_now)

    listed = Buddy::Context.send(:stashed_ideas, user)
    expect(listed.pluck(:id)).to eq([live.id])
    expect(listed.first).to include(category: "home", idea: "fix the gate")
  end
end
