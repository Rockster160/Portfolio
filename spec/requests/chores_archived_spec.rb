require "rails_helper"

RSpec.describe "Chores archived page", type: :request do
  let(:user) { create(:user) }
  let(:parent) {
    create(:chore, created_by_user: user, name: "Exercise", one_off: false, reward_pebbles: 0)
  }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  describe "GET /chores/archived" do
    it "lists archived chores (excluding active ones) and links unarchive form" do
      archived_sub = create(:chore, created_by_user: user, name: "Plunge",
                                    parent_chore: parent, one_off: true, reward_pebbles: 3)
      archived_sub.update!(archived_at: Time.current)
      _active = create(:chore, created_by_user: user, name: "Wash Dishes", one_off: false)

      get chores_archived_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Plunge")
      # Active chores must not appear as list items (they still show up as
      # options in the parent-chore dropdown, hence the more specific check).
      expect(response.body).to include(chore_routes_unarchive_path(archived_sub))
      expect(response.body).not_to include(chore_routes_unarchive_path(_active))
    end

    it "renders even when nothing is archived" do
      get chores_archived_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No archived chores")
    end
  end

  describe "POST /chores/items/:id/unarchive" do
    it "clears archived_at and broadcasts a chore change" do
      sub = create(:chore, created_by_user: user, parent_chore: parent, one_off: true)
      sub.update!(archived_at: Time.current)

      expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(user, kind_of(Chore)).at_least(:once)

      post chore_routes_unarchive_path(sub)
      expect(response).to redirect_to(chores_archived_path)
      expect(sub.reload.archived_at).to be_nil
    end
  end

  describe "editing an archived recurring sub-chore" do
    it "allows flipping one_off=false via PATCH /chores/items/:id and redirects back to archived" do
      sub = create(:chore, created_by_user: user, name: "Plunge",
                           parent_chore: parent, one_off: true, reward_pebbles: 3)
      sub.update!(archived_at: Time.current)

      patch chore_routes_item_path(sub),
        params:  { chore: { name: "Plunge", one_off: "0", parent_chore_id: parent.id.to_s, reward_pebbles: "4" } },
        headers: { "Referer" => chores_archived_path }

      expect(response).to redirect_to(chores_archived_path)
      sub.reload
      expect(sub.one_off).to eq(false)
      expect(sub.parent_chore_id).to eq(parent.id)
      expect(sub.reward_pebbles).to eq(4)
      expect(sub.archived_at).to be_present # edit does not un-archive; that's the separate button
    end
  end
end
