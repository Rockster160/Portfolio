require "rails_helper"

# The bulk group-mapping page: one row per chore with its groups editable in
# place. The page itself only lists and gates; the save it fires is the ordinary
# PATCH /chores/items/:id (tags_csv), covered in the chore/board specs.
RSpec.describe "Chore groups page", type: :request do
  let(:user) { create(:user) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  describe "GET /chores/groups" do
    it "lists every active chore with its groups as toggle chips" do
      create(:chore, created_by_user: user, name: "Vacuum", tags: ["Home", "Shared"], icon: "🧹")
      create(:chore, created_by_user: user, name: "Feed cat", tags: ["Pets"])

      get chores_groups_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Vacuum")
      expect(response.body).to include("Feed cat")
      expect(response.body).to include("🧹") # icon rendered next to the name
      # The palette is the union of everything set, drawn on every row.
      ["Home", "Pets", "Shared"].each do |g|
        expect(response.body).to include("data-group=\"#{g}\"")
      end
      # A chore's own groups come up pressed.
      expect(response.body).to include("aria-pressed=\"true\">Home")
      expect(response.body).to include("aria-pressed=\"true\">Pets")
    end

    it "renders with no chores" do
      household = ChoreHousehold.create!(name: "H", owner_user: user)
      user.update!(chore_household_id: household.id)

      get chores_groups_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No chores yet.")
    end

    it "turns a non-manager household member away" do
      owner = create(:user)
      household = ChoreHousehold.create!(name: "H", owner_user: owner)
      household.memberships.create!(user_id: user.id, role: :member)
      user.update!(chore_household_id: household.id)

      get chores_groups_path

      expect(response).to have_http_status(:redirect)
    end
  end
end
