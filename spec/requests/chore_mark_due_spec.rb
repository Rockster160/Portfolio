require "rails_helper"

RSpec.describe "Chore mark_due", type: :request do
  let(:user) { create(:user) }
  let!(:chore) { create(:chore, created_by_user: user, name: "Vacuum") }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def json = response.parsed_body

  describe "POST /chores/items/:id/mark_due" do
    it "stamps marked_due_at and returns the serialized chore" do
      post "/chores/items/#{chore.id}/mark_due"
      expect(response).to have_http_status(:ok)
      expect(chore.reload.marked_due_at).to be_present
      expect(Time.iso8601(json.dig("chore", "marked_due_at"))).to be_within(1.second).of(chore.marked_due_at)
      expect(json.dig("chore", "today_visible")).to be(true)
      expect(json.dig("chore", "due_today")).to be(true)
    end

    it "refreshes the timestamp on re-mark" do
      chore.update!(marked_due_at: 2.days.ago)
      old = chore.marked_due_at
      post "/chores/items/#{chore.id}/mark_due"
      expect(chore.reload.marked_due_at).to be > old
    end

    it "rejects chores the viewer cannot access" do
      stranger = create(:chore, name: "Not yours")
      post "/chores/items/#{stranger.id}/mark_due"
      expect(response).to have_http_status(:not_found).or have_http_status(:redirect)
      expect(stranger.reload.marked_due_at).to be_nil
    end
  end

  describe "DELETE /chores/items/:id/mark_due" do
    it "clears marked_due_at" do
      chore.update!(marked_due_at: Time.current)
      delete "/chores/items/#{chore.id}/mark_due"
      expect(response).to have_http_status(:ok)
      expect(chore.reload.marked_due_at).to be_nil
    end

    it "is a no-op when not currently marked" do
      delete "/chores/items/#{chore.id}/mark_due"
      expect(response).to have_http_status(:ok)
      expect(chore.reload.marked_due_at).to be_nil
    end
  end

  describe "PATCH /chores/items/:id with marked_due_at date string (form path)" do
    it "converts the date string to the chore-day start in the viewer's zone" do
      target = ChoreDay.current(user) + 3
      patch "/chores/items/#{chore.id}",
        params:  { chore: { marked_due_at: target.iso8601 } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(chore.reload.marked_due_at).to eq(ChoreDay.starts_at(target, user))
    end

    it "clears the stamp on blank submission" do
      chore.update!(marked_due_at: Time.current)
      patch "/chores/items/#{chore.id}",
        params:  { chore: { marked_due_at: "" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(chore.reload.marked_due_at).to be_nil
    end

    it "ignores unparseable date strings (treats as clear)" do
      chore.update!(marked_due_at: Time.current)
      patch "/chores/items/#{chore.id}",
        params:  { chore: { marked_due_at: "not a date" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(chore.reload.marked_due_at).to be_nil
    end
  end
end
