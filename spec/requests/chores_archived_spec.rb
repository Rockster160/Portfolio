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

    it "resolves hicon:<id> icons to inline <img> instead of raw text" do
      household = ChoreHousehold.create!(name: "H", owner_user: user).tap { |h|
        user.update!(chore_household_id: h.id)
      }
      tiny_png = "data:image/png;base64," \
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
      icon = HouseholdIcon.create!(chore_household: household, uploaded_by_user: user,
                                   name: "Cat", keywords: "", image_data: tiny_png)
      chore = create(:chore, created_by_user: user, name: "Feed Cat",
                             icon: "hicon:#{icon.id}", reward_pebbles: 1)
      chore.update!(archived_at: Time.current)

      get chores_archived_path
      # Raw ref must NOT leak into the DOM as text; the resolved data-URL is what feeds <img src>.
      expect(response.body).not_to include("hicon:#{icon.id}")
      expect(response.body).to include(tiny_png)
    end

    it "filters via the same search syntax as history (bare word + archived_at operator)" do
      old = create(:chore, created_by_user: user, name: "Bathroom Light")
      old.update!(archived_at: Time.zone.parse("2026-06-15 00:00:00"))
      new_one = create(:chore, created_by_user: user, name: "Bathroom Fan")
      new_one.update!(archived_at: Time.zone.parse("2026-07-25 00:00:00"))

      get chores_archived_path, params: { q: "light archived_at<2026-07-22" }
      expect(response.body).to include(chore_routes_unarchive_path(old))
      expect(response.body).not_to include(chore_routes_unarchive_path(new_one))
    end

    it "paginates with 25 per page" do
      Time.use_zone("America/Denver") {
        30.times { |i|
          c = create(:chore, created_by_user: user, name: "Old ##{i}")
          c.update!(archived_at: (i + 1).days.ago)
        }
      }

      get chores_archived_path
      # Page 1 shows 25 rows worth of unarchive forms.
      expect(response.body.scan("/unarchive").size).to eq(25)
      expect(response.body).to include("page 1 of 2")

      get chores_archived_path, params: { page: 2 }
      expect(response.body.scan("/unarchive").size).to eq(5)
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
