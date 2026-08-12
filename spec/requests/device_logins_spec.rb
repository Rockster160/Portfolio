require "rails_helper"

RSpec.describe "Device logins", type: :request do
  let(:user) { create(:user) }

  def sign_in_as(target)
    post login_path, params: { user: { username: target.username, password: "password123" } }
  end

  # /account signs anonymous visitors up as guests, so it can't tell us whether
  # a session took. /api_keys is behind `authorize_user`, and reloading the QR
  # page names the user the session actually belongs to.
  def signed_in?
    get api_keys_path
    response.status == 200
  end

  def session_user
    get device_login_path
    DeviceLoginToken.order(:id).last&.user
  end

  describe "GET /account/device_login" do
    it "requires a signed in user" do
      get device_login_path

      expect(response).to redirect_to(login_path)
      expect(DeviceLoginToken.count).to eq(0)
    end

    it "issues a token and renders the QR and the code" do
      sign_in_as(user)
      get device_login_path

      token = DeviceLoginToken.find_by(user: user)
      expect(token).to be_present
      expect(response.body).to include(token.formatted_code)
      expect(response.body).to include("<svg")
      # An XML prologue ahead of the <svg> is not valid inline in HTML.
      expect(response.body).not_to include("<?xml")
      # The QR carries the bearer token; nothing else on the page should.
      expect(response.body).not_to include(token.token)
    end

    it "replaces the previous token on reload" do
      sign_in_as(user)
      get device_login_path
      first = DeviceLoginToken.find_by(user: user)
      get device_login_path

      expect(DeviceLoginToken.where(user: user).count).to eq(1)
      expect(DeviceLoginToken.find_by(user: user).token).not_to eq(first.token)
    end
  end

  describe "GET /scan/:token" do
    it "signs the visitor in and burns the token" do
      token = DeviceLoginToken.issue!(user)

      get device_login_claim_path(token.token)

      expect(response).to redirect_to(root_path)
      expect(token.reload).to be_used
      expect(session_user).to eq(user)
    end

    it "rejects a reused token and leaves the visitor signed out" do
      token = DeviceLoginToken.issue!(user)
      get device_login_claim_path(token.token)
      reset!

      get device_login_claim_path(token.token)

      expect(response).to redirect_to(login_path)
      expect(signed_in?).to be(false)
    end

    it "rejects an expired token" do
      token = DeviceLoginToken.issue!(user)
      token.update!(expires_at: 1.second.ago)

      get device_login_claim_path(token.token)

      expect(response).to redirect_to(login_path)
    end
  end

  describe "POST /login with a device login code" do
    it "accepts the code in place of the password" do
      token = DeviceLoginToken.issue!(user)

      post login_path, params: { user: { username: user.username, password: token.code } }

      expect(response).to have_http_status(:redirect)
      expect(token.reload).to be_used
      expect(session_user).to eq(user)
    end

    it "does not accept the code twice" do
      token = DeviceLoginToken.issue!(user)
      post login_path, params: { user: { username: user.username, password: token.code } }
      reset!

      post login_path, params: { user: { username: user.username, password: token.code } }

      expect(signed_in?).to be(false)
    end

    it "still accepts the real password" do
      DeviceLoginToken.issue!(user)

      post login_path, params: { user: { username: user.username, password: "password123" } }

      expect(signed_in?).to be(true)
    end
  end
end
