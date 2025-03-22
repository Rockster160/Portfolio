# spec/requests/oauth_flow_spec.rb
require "rails_helper"

RSpec.describe "OAuth Flow", type: :request do
  let(:user)   { User.me }
  let(:client) do
    Doorkeeper::Application.create!(
      name:         "TestApp",
      redirect_uri: "https://pitangui.amazon.com/api/skill/link/M2Q6I8JY7FNG47"
    )
  end

  before do
    # request.headers["Content-Type"] = "application/json"
    # request.headers["Accept"] = "application/json"
    # Simulate a logged-in user
    allow_any_instance_of(ApplicationController)
      .to receive(:current_user).and_return(user)
      allow_any_instance_of(Doorkeeper::AuthorizationsController)
  .to receive(:current_user).and_return(user)
  end

  it "issues an authorization code" do
    get "/oauth/authorize", params: {
      response_type: "code",
      client_id:     client.uid,
      redirect_uri:  client.redirect_uri
    }, headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
    }
    expect(response).to be_redirect
    # Extract auth code from the redirect url query params if needed
  end

  it "exchanges code for token" do
    # First get the auth code
    get "/oauth/authorize", params: {
      response_type: "code",
      client_id:     client.uid,
      redirect_uri:  client.redirect_uri
    }, headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
    }
    auth_code = CGI.parse(URI.parse(response.location).query)["code"].first

    post "/oauth/token", params: {
      grant_type:    "authorization_code",
      code:          auth_code,
      client_id:     client.uid,
      client_secret: client.secret,
      redirect_uri:  client.redirect_uri
    }
    expect(response).to have_http_status(:success)
  end
end
