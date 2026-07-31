require "rails_helper"

RSpec.describe WebhooksController, type: :controller do
  let(:user)   { User.me }
  let(:secret) { "test-secret" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("BYTE_LOCAL_SECRET", "").and_return(secret)
    request.env["HTTP_X_BYTE_SECRET"] = secret
  end

  describe "GET #byte_agenda" do
    it "401s without the shared secret" do
      request.env["HTTP_X_BYTE_SECRET"] = "wrong"
      get :byte_agenda, params: { user_id: user.id, range: "today" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns a compact body + count for :upcoming" do
      get :byte_agenda, params: { user_id: user.id, range: "upcoming" }
      expect(response).to be_successful
      json = JSON.parse(response.body)
      expect(json).to include("range" => "upcoming", "count" => a_kind_of(Integer), "body" => a_kind_of(String))
    end

    it "accepts a free-form q that runs through AgendaItem.query" do
      get :byte_agenda, params: { user_id: user.id, q: "is:today" }
      expect(response).to be_successful
      json = JSON.parse(response.body)
      expect(json["range"]).to eq("is:today")
    end

    it "400s on an unknown range" do
      get :byte_agenda, params: { user_id: user.id, range: "yesteryear" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET #byte_weather" do
    it "401s without the shared secret" do
      request.env["HTTP_X_BYTE_SECRET"] = "wrong"
      get :byte_weather, params: { user_id: user.id }
      expect(response).to have_http_status(:unauthorized)
    end

    # Fetching and formatting moved into WeatherService (see
    # weather_service_spec for the one-liner itself); the endpoint is now just
    # a pass-through with an availability guard.
    it "returns 503 when there's no forecast to be had" do
      allow(WeatherService).to receive(:summary).and_return(nil)
      get :byte_weather, params: { user_id: user.id }
      expect(response).to have_http_status(:service_unavailable)
    end

    it "renders the service's one-liner" do
      allow(WeatherService).to receive(:summary)
        .and_return("currently 72°F, partly cloudy. today high 85°F / low 56°F, chance of rain 20%.")

      get :byte_weather, params: { user_id: user.id }

      expect(response).to be_successful
      json = JSON.parse(response.body)
      expect(json["body"]).to include("72°F", "partly cloudy", "high 85°F", "low 56°F", "chance of rain 20%")
    end
  end
end
