require "rails_helper"

# Curating what the companions have kept. Deliberately outside Byte: a companion
# that offers to manage its own memory in the chat is a companion spending the
# conversation on bookkeeping.
RSpec.describe SystemController, type: :controller do
  render_views

  let(:me)    { FactoryBot.create(:user, phone: "5550004000", role: :admin) }
  let(:other) { FactoryBot.create(:user, phone: "5550004001") }

  before do
    allow(User).to receive(:me).and_return(me)
    me_id = me.id
    allow_any_instance_of(User).to receive(:me?) { |u| u.id == me_id }
    sign_in(me)
  end

  let!(:preference) {
    me.buddy_memories.create!(kind: :preference, content: "Drinks oat milk lattes.", severity: 5, tags: %w[food])
  }
  let!(:followup) {
    me.buddy_memories.create!(
      kind: :followup, content: "Their cat is in hospital.", severity: 70,
      tags: %w[pets health], check_in_at: 2.days.from_now,
    )
  }
  let!(:theirs) {
    other.buddy_memories.create!(kind: :concept, content: "Their own private thing.", severity: 20)
  }

  describe "GET #memories" do
    it "lists everything the companions are holding, weightiest first" do
      get(:memories)

      expect(response).to have_http_status(:ok)
      # Weightiest first: the cat (70) above the latte preference (5).
      expect(response.body.index("cat is in hospital")).to be < response.body.index("oat milk lattes")
      expect(response.body).to include("Their own private thing.", "3 total")
    end

    it "narrows by kind" do
      get(:memories, params: { kind: "followup" })

      expect(response.body).to include("cat is in hospital")
      expect(response.body).not_to include("oat milk lattes")
    end

    it "narrows by tag" do
      get(:memories, params: { tag: "pets" })

      expect(response.body).to include("cat is in hospital")
      expect(response.body).not_to include("Their own private thing.")
    end

    it "narrows by person" do
      get(:memories, params: { user_id: other.id })

      expect(response.body).to include("Their own private thing.")
      expect(response.body).not_to include("cat is in hospital")
    end

    it "searches the prose" do
      get(:memories, params: { q: "hospital" })

      expect(response.body).to include("cat is in hospital")
      expect(response.body).not_to include("oat milk lattes")
    end

    it "offers the tags actually in use, commonest first" do
      get(:memories)

      tags = response.body[%r{<div class="memories-tags">.*?</div>}m].to_s
      expect(tags).to include("pets", "health", "food")
    end

    it "is refused to anyone who isn't me" do
      allow(User).to receive(:me).and_return(other)
      allow_any_instance_of(User).to receive(:me?).and_return(false)

      get(:memories)

      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "PATCH #update_memory" do
    it "edits a severity that landed too high" do
      patch(:update_memory, params: { id: followup.id, severity: 30 })

      expect(response).to have_http_status(:ok)
      expect(followup.reload.severity).to eq(30)
    end

    it "clamps a severity outside the scale rather than storing it" do
      patch(:update_memory, params: { id: followup.id, severity: 500 })

      expect(followup.reload.severity).to eq(100)
    end

    it "rewrites content that came out wrong" do
      patch(:update_memory, params: { id: followup.id, content: "Their cat came home." })

      expect(followup.reload.content).to eq("Their cat came home.")
    end

    it "retags" do
      patch(:update_memory, params: { id: followup.id, tags: "Pets, Vet " })

      expect(followup.reload.tag_list).to eq(%w[pets vet])
    end

    it "moves something into a different kind" do
      patch(:update_memory, params: { id: preference.id, kind: "concept" })

      expect(preference.reload).to be_kind_concept
    end

    # The likeliest reason to open this page at all.
    it "disarms a check-in without deleting the memory" do
      patch(:update_memory, params: { id: followup.id, check_in_at: "" })

      expect(followup.reload.check_in_at).to be_nil
      expect(followup).to be_persisted
    end

    it "refuses an edit the model itself would refuse" do
      patch(:update_memory, params: { id: followup.id, content: "" })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(followup.reload.content).to eq("Their cat is in hospital.")
    end
  end

  describe "DELETE #destroy_memory" do
    it "deletes one that landed wrong" do
      expect { delete(:destroy_memory, params: { id: followup.id }) }
        .to change(BuddyMemory, :count).by(-1)
    end

    it "takes its notes with it" do
      followup.notes.create!(body: "still in overnight")

      delete(:destroy_memory, params: { id: followup.id })

      expect(BuddyMemoryNote.where(buddy_memory_id: followup.id)).to be_empty
    end
  end
end
