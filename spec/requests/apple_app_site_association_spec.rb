require "rails_helper"

RSpec.describe "Apple app site association", type: :request do
  it "names the Buddy app for the site's saved passwords", :aggregate_failures do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PORTFOLIO_APNS_TEAM_ID", nil).and_return("TEAM123456")

    expect { get "/.well-known/apple-app-site-association" }.not_to change(User, :count)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("webcredentials" => { "apps" => ["TEAM123456.com.ardesian.buddy"] })
  end
end
