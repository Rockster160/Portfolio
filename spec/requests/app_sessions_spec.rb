require "rails_helper"

RSpec.describe "Buddy app login page", type: :request do
  let(:user) { User.me }
  let(:device) { { name: "Rocco's iPhone", model: "iPhone18,1", os_version: "27.2", app_version: "1.0" } }

  let(:in_app) { { "User-Agent" => "Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 BuddyiOS" } }

  before { user.update!(password: "password123", password_confirmation: "password123") }

  def log_in!(password: "password123")
    post app_login_path,
      params:  { user: { username: user.username, password: password }, device: device },
      headers: in_app
  end

  it "sends a browser to the site's own login without making a device", :aggregate_failures do
    post app_login_path, params: { user: { username: user.username, password: "password123" }, device: device }

    expect(response).to redirect_to(login_path)
    expect(AppDevice.count).to eq(0)
  end

  it "is a login form carrying what the phone is", :aggregate_failures do
    get app_login_path, params: { device: device }, headers: in_app

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Log in", "Privacy Policy", "Support", "Rocco&#39;s iPhone")
  end

  it "issues the phone its own token and signs the web view in", :aggregate_failures do
    log_in!

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    app_device = AppDevice.last
    expect(app_device).to have_attributes(user_id: user.id, name: "Rocco's iPhone", os_version: "27.2")
    expect(app_device.features).to include("battery", "widgets")
    expect(app_device.features).not_to include("push", "location")

    handoff = JSON.parse(Nokogiri::HTML(response.body).at("[data-buddy-signed-in]")["data-buddy-signed-in"])
    expect(handoff["token"]).to start_with("bdy_")
    expect(AppDevice.authenticate(handoff["token"])).to eq(app_device)

    get app_settings_path
    expect(response).to redirect_to(app_device_path(app_device))
  end

  it "refuses a wrong password", :aggregate_failures do
    log_in!(password: "nope")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Username and password combination not found.")
    expect(AppDevice.count).to eq(0)
  end
end
