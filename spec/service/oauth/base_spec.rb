require "rails_helper"

RSpec.describe Oauth::Base do
  describe ".from_jwt" do
    let(:user) { create(:user, phone: "5550000099") }

    it "returns nil for a nil token (callsites use `&.code =`)" do
      expect(Oauth::GoogleApi.from_jwt(nil)).to be_nil
    end

    it "returns nil for a blank token" do
      expect(Oauth::GoogleApi.from_jwt("")).to be_nil
      expect(Oauth::GoogleApi.from_jwt("   ")).to be_nil
    end

    it "returns nil for a malformed token instead of raising JWT::DecodeError" do
      expect(Oauth::GoogleApi.from_jwt("not.a.jwt")).to be_nil
      expect(Oauth::GoogleApi.from_jwt("garbage")).to be_nil
    end

    it "returns nil for a JWT signed with a different secret" do
      foreign = JWT.encode(
        { user_id: user.id, service: "google_api", timestamp: Time.now.to_i },
        "different-secret",
        "HS256",
      )
      expect(Oauth::GoogleApi.from_jwt(foreign)).to be_nil
    end

    it "returns nil for a JWT older than STATE_JWT_TTL" do
      stale = JWT.encode(
        { user_id: user.id, service: "google_api", timestamp: (Oauth::Base::STATE_JWT_TTL + 1.minute).ago.to_i },
        Rails.application.secret_key_base,
        "HS256",
      )
      expect(Oauth::GoogleApi.from_jwt(stale)).to be_nil
    end

    it "returns nil when service doesn't match the class" do
      mismatched = JWT.encode(
        { user_id: user.id, service: "spotify_api", timestamp: Time.now.to_i },
        Rails.application.secret_key_base,
        "HS256",
      )
      expect(Oauth::GoogleApi.from_jwt(mismatched)).to be_nil
    end

    it "returns an instance for a fresh, well-formed token" do
      api = Oauth::GoogleApi.new(user)
      decoded = Oauth::GoogleApi.from_jwt(api.jwt)
      expect(decoded).to be_a(Oauth::GoogleApi)
    end
  end

  describe "where credentials live" do
    let(:user) { create(:user) }
    let(:api) { described_class.new(user, service: "spotify_api") }

    def secret(field) = user.secrets.named("oauth:spotify_api:#{field}")
    def cached = user.caches.by(:oauth).reload.data.to_h.deep_stringify_keys["spotify_api"].to_h

    it "keeps the secret fields encrypted in the user's secrets, never in the cache" do
      api.client_id = "client-123"
      api.client_secret = "shh"
      api.access_token = "acc"
      api.refresh_token = "ref"
      api.id_token = "idt"

      expect(secret(:client_secret).value).to eq("shh")
      expect(secret(:access_token).value).to eq("acc")
      expect(cached).to eq("client_id" => "client-123")
    end

    it "reads them back through a fresh instance" do
      api.client_secret = "shh"
      api.access_token = "acc"

      fresh = described_class.new(user, service: "spotify_api")
      expect(fresh.client_secret).to eq("shh")
      expect(fresh.access_token).to eq("acc")
      expect(fresh.base_headers[:Authorization]).to eq("Bearer acc")
    end

    it "writes the tokens an exchange hands back into secrets" do
      allow(Api).to receive(:post).and_return({ access_token: "new-acc", refresh_token: "new-ref" })

      api.refresh

      expect(secret(:access_token).value).to eq("new-acc")
      expect(secret(:refresh_token).value).to eq("new-ref")
      expect(cached).not_to have_key("access_token")
    end

    it "updates one row per field rather than piling them up" do
      api.access_token = "one"
      api.access_token = "two"

      expect(user.secrets.where("name LIKE 'oauth:%'").count).to eq(1)
      expect(secret(:access_token).value).to eq("two")
    end

    it "leaves the secret out of the hash Jil carries around" do
      api.client_secret = "shh"

      expect(api.to_h.to_s).not_to include("shh")
    end
  end
end
