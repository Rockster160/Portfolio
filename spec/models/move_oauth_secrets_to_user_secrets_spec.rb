require "rails_helper"
require Rails.root.join("db/migrate/20261006191259_move_oauth_secrets_to_user_secrets")

RSpec.describe MoveOauthSecretsToUserSecrets do
  let(:user) { create(:user) }
  let(:cache) { user.caches.by(:oauth) }

  def migrate!(direction=:up)
    described_class.new.tap { |m| m.verbose = false }.public_send(direction)
  end

  before do
    cache.update!(data: {
      spotify_api: { client_id: "cid", client_secret: "shh", access_token: "acc", refresh_token: "ref" },
      venmo_api:   { access_token: "vacc", contact_ids: { "12" => "mom" }, device_id: "dev" },
    })
  end

  it "moves the secret fields out of the cache and leaves everything else" do
    migrate!

    expect(Oauth::Base.new(user, service: "spotify_api").client_secret).to eq("shh")
    expect(Oauth::Base.new(user, service: "spotify_api").refresh_token).to eq("ref")
    expect(Oauth::Base.new(user, service: "venmo_api").access_token).to eq("vacc")
    expect(cache.reload.data.deep_stringify_keys).to eq(
      "spotify_api" => { "client_id" => "cid" },
      "venmo_api"   => { "contact_ids" => { "12" => "mom" }, "device_id" => "dev" },
    )
  end

  it "is safe to run again" do
    migrate!
    migrate!

    expect(user.secrets.count).to eq(4)
  end

  it "puts them back on the way down" do
    migrate!
    migrate!(:down)

    expect(user.secrets.count).to eq(0)
    expect(cache.reload.data.deep_stringify_keys.dig("spotify_api", "client_secret")).to eq("shh")
    expect(cache.reload.data.deep_stringify_keys.dig("venmo_api", "access_token")).to eq("vacc")
  end
end
