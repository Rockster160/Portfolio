require "rails_helper"

RSpec.describe "Buddy app device API", type: :request do
  let(:user) { User.me }

  it "locks a revoked device out", :aggregate_failures do
    device, token = AppDevice.issue!(user, name: "Old phone")
    headers = { "Authorization" => "Bearer #{token}" }

    delete "/api/ios/session", headers: headers
    expect(response).to have_http_status(:ok)
    expect(device.reload).to be_revoked

    get "/api/ios/device", headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a request with no token" do
    get "/api/ios/catalog"

    expect(response).to have_http_status(:unauthorized)
  end

  it "takes what iOS allows and merges push-to-start tokens", :aggregate_failures do
    device, token = AppDevice.issue!(user, name: "Phone", push_to_start_tokens: { "other" => "aa" })
    patch "/api/ios/device", params: {
      permissions:          { location: "granted", health: "denied", teleport: "granted", contacts: "maybe" },
      push_to_start_tokens: { timer: "beef" },
      apns_token:           "cafe",
      turn_on:              ["location", "health"],
      features:             ["contacts"],
      preferences:          { push_badges: false },
    }, headers: { "Authorization" => "Bearer #{token}" }, as: :json

    device.reload
    expect(device.permissions).to eq("location" => "granted", "health" => "denied")
    expect(device.features).to include("location", "battery")
    expect(device.features).not_to include("health", "contacts")
    expect(device.push_to_start_tokens).to eq("other" => "aa", "timer" => "beef")
    expect(device.preference?(:push_badges)).to be(true)
  end

  it "switches a feature off when iOS stops allowing it" do
    device, token = AppDevice.issue!(user, name: "Phone", permissions: { location: "granted" })
    device.update!(features: device.features + ["location"])

    patch "/api/ios/device", params: { permissions: { location: "denied" } },
      headers: { "Authorization" => "Bearer #{token}" }, as: :json

    expect(device.reload.features).not_to include("location")
  end

  it "takes a push token off an older install that still holds it" do
    old_device, = AppDevice.issue!(user, name: "Before reinstall", apns_token: "cafe")
    _, token = AppDevice.issue!(user, name: "After reinstall")

    patch "/api/ios/device", params: { apns_token: "cafe" }, headers: { "Authorization" => "Bearer #{token}" }, as: :json

    expect(old_device.reload.apns_token).to be_nil
  end

  it "signs the web view in and only follows its own site" do
    _, token = AppDevice.issue!(user, name: "Phone")
    headers = { "Authorization" => "Bearer #{token}" }

    get "/api/ios/web_session", params: { to: "https://evil.example/" }, headers: headers
    expect(response).to redirect_to("/")

    get "/api/ios/web_session", params: { to: "/agenda" }, headers: headers
    expect(response).to redirect_to("/agenda")
  end
end
