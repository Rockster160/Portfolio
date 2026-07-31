require "rails_helper"

RSpec.describe "Rack::Attack blocklist for /recipes/print", type: :request do
  around do |example|
    prior = Rack::Attack.enabled
    Rack::Attack.reset!
    Rack::Attack.enabled = true
    example.run
    Rack::Attack.enabled = prior
  end

  it "returns 403 for a cookieless request, before it reaches Rails" do
    expect {
      get "/recipes/print"
    }.not_to change(User, :count)

    expect(response).to have_http_status(:forbidden)
  end

  it "does not block a request that carries a session cookie" do
    get "/recipes/print", headers: { "Cookie" => "_Portfolio_session=whatever" }

    expect(response).not_to have_http_status(:forbidden)
  end
end
