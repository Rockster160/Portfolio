require "rails_helper"

# Each pet's install manifests are generated from its companion class rather
# than kept as hand-written files.
RSpec.describe "Byte install manifests", type: :request do
  before { host! "byte.example.com" }

  # A browser fetches a manifest with no cookies, so it can't sit behind login.
  it "serves a pet's chat manifest without a session", :aggregate_failures do
    get "/suki.webmanifest"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/manifest+json")
    expect(JSON.parse(response.body)).to include(
      "name"             => "Suki",
      "id"               => "suki",
      "start_url"        => "/?source=pwa",
      "theme_color"      => "#150A22",
      "background_color" => "#150A22",
      "description"      => "Your bright little garden companion.",
    )
  end

  it "serves the kiosk manifest, opening the wall view" do
    get "/moss_kiosk.webmanifest"

    expect(JSON.parse(response.body)).to include(
      "name"             => "Moss Kiosk",
      "id"               => "moss-kiosk",
      "start_url"        => "/kiosk",
      "orientation"      => "any",
      "theme_color"      => "#14231A",
      "background_color" => "#0E1C0B",
    )
  end

  it "has nothing for a pet that doesn't exist" do
    get "/nobody.webmanifest"

    expect(response).to have_http_status(:not_found)
  end

  # The link on the page is what an install actually follows.
  it "is what the Byte page links to" do
    user = User.me
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
    user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current).update!(buddy_theme: :glimmer)

    get "/"
    href = response.body[/<link rel="manifest" href="([^"]+)"/, 1]
    get href

    expect(JSON.parse(response.body)["name"]).to eq("Glimmer")
  end
end
