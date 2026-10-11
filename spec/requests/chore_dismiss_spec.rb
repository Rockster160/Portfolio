require "rails_helper"

# Waving a chore off WITHOUT settling the occurrence — the "not today" the
# chore model had no way to say. The other gesture, `occurrence_skipped`
# (chore_completions#skip), lets the occurrence go and sends the chore away
# until it is next due; this one leaves the cycle exactly where it was.
#
# The thing most worth pinning down is what a dismissal does NOT do: no
# completion row, so nobody is credited, nothing is paid, and no streak is
# touched. "Not relevant today" must not cost anything.
RSpec.describe "Chore dismiss", type: :request do
  let(:user) { create(:user) }
  let!(:chore) { create(:chore, created_by_user: user, name: "Vacuum", reward_pebbles: 5) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def json = response.parsed_body

  describe "POST /chores/items/:chore_id/dismiss" do
    it "waves it off for the chore-day and says so in the serialized chore" do
      post "/chores/items/#{chore.id}/dismiss", params: { span: "day" }

      expect(response).to have_http_status(:ok)
      expect(chore.reload.dismissed_until).to eq(ChoreDay.current(user))
      expect(json.dig("chore", "dismissed")).to be(true)
      expect(json.dig("chore", "dismissed_until")).to eq(ChoreDay.current(user).iso8601)
    end

    it "defaults to the day when no span is given" do
      post "/chores/items/#{chore.id}/dismiss"

      expect(chore.reload.dismissed_until).to eq(ChoreDay.current(user))
    end

    it "reaches a week out" do
      post "/chores/items/#{chore.id}/dismiss", params: { span: "week" }

      expect(chore.reload.dismissed_until).to eq(ChoreDay.current(user) + 7)
    end

    # Calendar arithmetic, not 30 days: "not this month" said on the 31st
    # should not quietly become five weeks.
    it "reaches a calendar month out" do
      post "/chores/items/#{chore.id}/dismiss", params: { span: "month" }

      expect(chore.reload.dismissed_until).to eq(ChoreDay.current(user) + 1.month)
    end

    # The whole point of the gesture. A dismissal that cost a payout or broke a
    # streak would be a skip wearing a softer word.
    it "writes no completion, pays nothing and credits nobody" do
      expect { post "/chores/items/#{chore.id}/dismiss", params: { span: "day" } }
        .not_to change(ChoreCompletion, :count)

      expect(user.reload.chore_balance).to eq(0)
      expect(json.dig("chore", "progress_count")).to eq(0)
      expect(json.dig("chore", "skipped_today")).to be(false)
    end

    # `today_visible?` answers "would this have been on Today", and carryover
    # and the lookahead are built on that answer. A dismissal greys the chore;
    # it does not take it off the day.
    it "leaves the chore on Today, greyed rather than gone" do
      # Marked due, so it is genuinely ON the day before being waved off -
      # otherwise `today_visible` would be answering about the schedule rather
      # than about the dismissal.
      chore.update!(marked_due_at: Time.current)

      post "/chores/items/#{chore.id}/dismiss", params: { span: "day" }

      expect(json.dig("chore", "today_visible")).to be(true)
      expect(json.dig("chore", "dismissed")).to be(true)
    end

    it "refuses a span it doesn't know rather than guessing one" do
      post "/chores/items/#{chore.id}/dismiss", params: { span: "fortnight" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(chore.reload.dismissed_until).to be_nil
    end

    it "rejects a chore the viewer cannot reach" do
      stranger = create(:chore, name: "Not yours")
      post "/chores/items/#{stranger.id}/dismiss", params: { span: "day" }

      expect(response).to have_http_status(:not_found).or have_http_status(:redirect)
      expect(stranger.reload.dismissed_until).to be_nil
    end
  end

  describe "DELETE /chores/items/:chore_id/dismiss" do
    it "brings it back now instead of when the wave-off runs out" do
      chore.update!(dismissed_until: ChoreDay.current(user) + 7)

      delete "/chores/items/#{chore.id}/dismiss"

      expect(response).to have_http_status(:ok)
      expect(chore.reload.dismissed_until).to be_nil
      expect(json.dig("chore", "dismissed")).to be(false)
    end

    it "is fine on a chore that was never waved off" do
      delete "/chores/items/#{chore.id}/dismiss"

      expect(response).to have_http_status(:ok)
      expect(chore.reload.dismissed_until).to be_nil
    end
  end

  describe "GET /chores/tags" do
    it "lists what the household has filed things under, and nothing else" do
      chore.update!(tag: "Home")
      create(:chore, created_by_user: user, name: "Water plants", tag: "Pets")
      create(:chore, created_by_user: user, name: "Untagged")
      create(:chore, name: "Someone else's", tag: "Theirs")

      get "/chores/tags"

      expect(json["tags"]).to eq(["Home", "Pets"])
    end
  end
end
