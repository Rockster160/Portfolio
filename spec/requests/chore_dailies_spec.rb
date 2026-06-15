require "rails_helper"

RSpec.describe "Chore Dailies", type: :request do
  let(:user) { create(:user) }
  let!(:chore_a) { create(:chore, created_by_user: user, name: "Brush") }
  let!(:chore_b) { create(:chore, created_by_user: user, name: "Vitamins") }
  let!(:chore_c) { create(:chore, created_by_user: user, name: "Floss") }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def json
    response.parsed_body
  end

  describe "POST /chores/items/:id/dailies" do
    it "pins a chore for the current user and returns the ordered daily_ids" do
      post "/chores/items/#{chore_a.id}/dailies",
        params:  {}.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(ChoreDaily.where(user: user, chore: chore_a)).to exist
      expect(json["daily_ids"]).to eq([chore_a.id])
    end

    it "is idempotent — re-pinning does not duplicate or change order" do
      post "/chores/items/#{chore_a.id}/dailies"
      post "/chores/items/#{chore_b.id}/dailies"
      post "/chores/items/#{chore_a.id}/dailies"
      expect(ChoreDaily.where(user: user).count).to eq(2)
      expect(json["daily_ids"]).to eq([chore_a.id, chore_b.id])
    end

    it "rejects pinning chores the viewer cannot access" do
      stranger_chore = create(:chore, name: "Not yours")
      post "/chores/items/#{stranger_chore.id}/dailies"
      expect(response).to have_http_status(:not_found).or have_http_status(:redirect)
      expect(ChoreDaily.where(user: user)).to be_empty
    end
  end

  describe "DELETE /chores/items/:id/dailies" do
    it "unpins a previously pinned chore" do
      ChoreDaily.create!(user: user, chore: chore_a, sort_order: 0)
      ChoreDaily.create!(user: user, chore: chore_b, sort_order: 1)
      delete "/chores/items/#{chore_a.id}/dailies"
      expect(response).to have_http_status(:ok)
      expect(ChoreDaily.where(user: user, chore: chore_a)).to be_empty
      expect(json["daily_ids"]).to eq([chore_b.id])
    end

    it "is a no-op when the chore was never pinned" do
      delete "/chores/items/#{chore_a.id}/dailies"
      expect(response).to have_http_status(:ok)
      expect(json["daily_ids"]).to eq([])
    end
  end

  describe "PATCH /chores/dailies/order" do
    it "reorders the viewer's pins by the supplied id list" do
      ChoreDaily.create!(user: user, chore: chore_a, sort_order: 0)
      ChoreDaily.create!(user: user, chore: chore_b, sort_order: 1)
      ChoreDaily.create!(user: user, chore: chore_c, sort_order: 2)

      patch "/chores/dailies/order",
        params:  { ids: [chore_c.id, chore_a.id, chore_b.id] }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(json["daily_ids"]).to eq([chore_c.id, chore_a.id, chore_b.id])
    end

    it "ignores ids that don't belong to the viewer's pins" do
      ChoreDaily.create!(user: user, chore: chore_a, sort_order: 0)
      patch "/chores/dailies/order",
        params:  { ids: [chore_a.id, 99_999] }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(json["daily_ids"]).to eq([chore_a.id])
    end
  end

  describe "hydration via /chores/sync" do
    # The unified Grid/Today shell is data-free now — daily_ids
    # arrive client-side from the /chores/sync envelope, never inline
    # in the HTML. Assert against /chores/sync directly.
    it "GET /chores/sync returns daily_ids in the viewer's pin order" do
      ChoreDaily.create!(user: user, chore: chore_b, sort_order: 0)
      ChoreDaily.create!(user: user, chore: chore_a, sort_order: 1)
      get chores_sync_path
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["daily_ids"]).to eq([chore_b.id, chore_a.id])
    end

    it "GET /chores/sync echoes a single daily pin" do
      ChoreDaily.create!(user: user, chore: chore_a, sort_order: 0)
      get chores_sync_path
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["daily_ids"]).to eq([chore_a.id])
    end
  end
end
