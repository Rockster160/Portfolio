require "rails_helper"

RSpec.describe "Household Icons API", type: :request do
  let(:user) { create(:user) }
  let!(:household) {
    ChoreHousehold.create!(name: "Home", owner_user: user).tap { |h|
      user.update!(chore_household_id: h.id)
    }
  }
  let(:tiny_png_url) {
    "data:image/png;base64," \
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
  }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  describe "GET /chores/household_icons.json" do
    it "returns the household's icons in pool-row shape" do
      HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: user,
        name: "Whisper", keywords: "cat", image_data: tiny_png_url,
      )

      get chores_household_icons_index_path
      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body.first).to include("c" => tiny_png_url, "n" => "Whisper")
      expect(body.first["k"]).to include("cat", "whisper")
    end
  end

  describe "POST /chores/household_icons" do
    it "creates an icon" do
      post chore_routes_household_icons_path,
        params: { household_icon: { name: "Floss", keywords: "teeth", image_data: tiny_png_url } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:created)
      icon = HouseholdIcon.last
      expect(icon.name).to eq("Floss")
      expect(icon.uploaded_by_user_id).to eq(user.id)
    end

    it "422s on bad image_data" do
      post chore_routes_household_icons_path,
        params: { household_icon: { name: "Bad", image_data: "https://nope" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /chores/household_icons/:id" do
    it "updates name + keywords" do
      icon = HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: user,
        name: "Old", image_data: tiny_png_url,
      )

      patch chore_routes_household_icon_path(icon),
        params: { household_icon: { name: "New", keywords: "fresh" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(icon.reload.name).to eq("New")
      expect(icon.keywords).to eq("fresh")
    end
  end

  describe "DELETE /chores/household_icons/:id" do
    it "removes the icon" do
      icon = HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: user,
        name: "Doomed", image_data: tiny_png_url,
      )

      expect {
        delete chore_routes_household_icon_path(icon),
          headers: { "ACCEPT" => "application/json" }
      }.to change(HouseholdIcon, :count).by(-1)
      expect(response).to have_http_status(:ok)
    end
  end
end
