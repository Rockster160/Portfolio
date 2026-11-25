require "rails_helper"

RSpec.describe "Rack::Attack blocklist for crawler IP ranges", type: :request do
  around do |example|
    prior = Rack::Attack.enabled
    Rack::Attack.reset!
    Rack::Attack.enabled = true
    example.run
    Rack::Attack.enabled = prior
  end

  it "returns 403 to any address in the blocked range, before a guest is minted" do
    expect {
      get "/action_events/calendar", env: { "REMOTE_ADDR" => "57.141.20.77" }
    }.not_to change(User, :count)

    expect(response).to have_http_status(:forbidden)
  end

  it "leaves the neighboring Meta ranges open" do
    get "/", env: { "REMOTE_ADDR" => "57.141.22.5" }

    expect(response).not_to have_http_status(:forbidden)
  end
end
