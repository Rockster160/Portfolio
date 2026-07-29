require "rails_helper"

RSpec.describe ApplicationController, type: :controller do
  controller do
    def index
      head :ok
    end
  end

  let(:banned_ip) { "203.0.113.7" }

  before do
    request.remote_addr = banned_ip
    BannedIp.create!(ip: banned_ip, whitelisted: false)
    User.find_or_create_by!(id: 58_128) { |u| u.username = "chelsea"; u.password = "password123"; u.password_confirmation = "password123" }
    User.find_or_create_by!(id: 4) { |u| u.username = "eve"; u.password = "password123"; u.password_confirmation = "password123" }
  end

  it "blocks a banned IP for a non-perma-safe user" do
    user = User.create!(username: "randobehindhomeip", password: "password123", password_confirmation: "password123")
    sign_in(user)
    get :index
    expect(response).to have_http_status(:unauthorized)
  end

  it "lets Chelsea through even when the shared home IP is banned" do
    sign_in(User.chelsea)
    get :index
    expect(response).to have_http_status(:ok)
  end

  it "lets Eve through even when the shared home IP is banned" do
    sign_in(User.eve)
    get :index
    expect(response).to have_http_status(:ok)
  end

  it "treats perma-safe users as whitelisted so they never get banned" do
    sign_in(User.chelsea)
    get :index
    expect(controller.send(:ip_whitelisted?)).to be(true)
  end
end
