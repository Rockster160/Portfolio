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

    it "returns 503 when the API key is missing" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("WEATHER_APIKEY").and_return("")
      get :byte_weather, params: { user_id: user.id }
      expect(response).to have_http_status(:service_unavailable)
    end

    it "formats the OpenWeather payload into a compact one-liner" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("WEATHER_APIKEY").and_return("stub")

      fake_body = JSON.generate(
        current: { temp: 72.4, feels_like: 70.1, weather: [{ description: "partly cloudy" }] },
        daily:   [{ temp: { max: 85.2, min: 55.8 }, pop: 0.2 }],
      )
      fake_res = instance_double(Net::HTTPOK, is_a?: true, body: fake_body)
      allow(fake_res).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:start).and_yield(double(get: fake_res))

      get :byte_weather, params: { user_id: user.id }
      expect(response).to be_successful
      json = JSON.parse(response.body)
      expect(json["body"]).to include("72°F", "partly cloudy", "high 85°F", "low 56°F", "chance of rain 20%")
    end
  end
end
