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
end
