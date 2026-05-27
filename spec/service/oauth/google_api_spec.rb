require "rails_helper"

RSpec.describe Oauth::GoogleApi do
  let(:user) { create(:user, phone: "5550000077") }
  let(:account) {
    GoogleAccount.create!(
      user: user, email: "alice@example.com",
      access_token: "old-access", refresh_token: "good-refresh"
    )
  }

  describe "token storage when bound to a GoogleAccount" do
    let(:api) { described_class.for_account(account) }

    it "reads tokens from the GoogleAccount, not the cache" do
      expect(api.access_token).to eq("old-access")
      expect(api.refresh_token).to eq("good-refresh")
    end

    it "writes tokens to the GoogleAccount columns" do
      api.access_token = "fresh-access"
      expect(account.reload.access_token).to eq("fresh-access")
    end

    it "keeps the existing refresh_token when the response omits one (Google's normal refresh behavior)" do
      api.refresh_token = nil
      expect(account.reload.refresh_token).to eq("good-refresh")
    end
  end

  describe "#auth on a bound account (refresh path)" do
    let(:api) { described_class.for_account(account) }

    it "saves the refreshed access_token to the GoogleAccount, not to the cache" do
      allow(Api).to receive(:post).and_return({
        access_token: "freshly-refreshed",
        expires_in:   3599,
        token_type:   "Bearer",
      })

      api.auth(grant_type: :refresh_token, refresh_token: account.refresh_token)
      expect(account.reload.access_token).to eq("freshly-refreshed")
      # And the read-through goes through the column, not the cache.
      expect(api.access_token).to eq("freshly-refreshed")
    end

    it "keeps the prior refresh_token when Google omits it on the refresh response" do
      allow(Api).to receive(:post).and_return({
        access_token: "freshly-refreshed",
        expires_in:   3599,
      })
      api.auth(grant_type: :refresh_token, refresh_token: account.refresh_token)
      expect(account.reload.refresh_token).to eq("good-refresh")
    end

    it "marks the account needs_reauth on 400 invalid_grant + returns nil" do
      err = RestClient::BadRequest.new(instance_double(RestClient::Response, code: 400, body: "{}"))
      allow(Api).to receive(:post).and_raise(err)

      result = api.auth(grant_type: :refresh_token, refresh_token: account.refresh_token)
      expect(result).to be_nil
      expect(account.reload).to be_needs_reauth
    end

    it "clears reauth_required_at on a successful refresh" do
      account.update!(reauth_required_at: 1.day.ago)
      allow(Api).to receive(:post).and_return({ access_token: "fresh" })
      api.auth(grant_type: :refresh_token, refresh_token: account.refresh_token)
      expect(account.reload.reauth_required_at).to be_nil
    end
  end

  describe "#auth during the initial OAuth exchange (unbound)" do
    let(:api) { described_class.new(user) }
    let(:id_token) { JWT.encode({ "email" => "bob@example.com" }, nil, "none") }

    it "materializes a GoogleAccount + binds the api instance to it" do
      allow(Api).to receive(:post).and_return({
        access_token:  "ya29.access",
        refresh_token: "1//refresh",
        id_token:      id_token,
      })

      api.code = "abc"

      account = user.google_accounts.find_by(email: "bob@example.com")
      expect(account).to be_present
      expect(account.access_token).to eq("ya29.access")
      expect(account.refresh_token).to eq("1//refresh")
      expect(api.google_account).to eq(account)
    end
  end
end
