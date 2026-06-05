require "rails_helper"

RSpec.describe TimerSharesController do
  let(:owner) { create(:user) }
  let(:timer) { create(:timer, user: owner, duration_ms: 60_000) }

  describe "GET /t/:token" do
    it "returns 410 when token is missing" do
      get "/t/does-not-exist"
      expect(response).to have_http_status(:gone)
    end

    it "renders for a valid view_only share without auth" do
      share = TimerShareToken.create!(user: owner, timer: timer, access_mode: :view_only)
      get "/t/#{share.token}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("timers-share-page")
    end

    it "returns 410 after revocation" do
      share = TimerShareToken.create!(user: owner, timer: timer, access_mode: :view_only)
      share.revoke!
      get "/t/#{share.token}"
      expect(response).to have_http_status(:gone)
    end
  end

  describe "POST /t/:token/:action_kind" do
    context "view_only" do
      it "rejects mutations with 403" do
        share = TimerShareToken.create!(user: owner, timer: timer, access_mode: :view_only)
        post "/t/#{share.token}/start", params: { timer_id: timer.id }, as: :json
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "interactive" do
      it "starts the timer" do
        share = TimerShareToken.create!(user: owner, timer: timer, access_mode: :interactive)
        Sidekiq::Testing.fake! do
          post "/t/#{share.token}/start", params: { timer_id: timer.id }, as: :json
        end
        expect(response).to have_http_status(:ok)
        expect(timer.reload.started_at).to be_present
      end
    end
  end
end
