require "rails_helper"

# Reproduces the "logged in but landed on the wrong page" bug: visiting a
# protected page while logged out should send you BACK to that page after
# login, not to the /lists fallback. The session cookie is secure-only, so the
# flow must run over https for the cookie to persist across requests.
RSpec.describe "Post-login forwarding", type: :request do
  let(:user) { create(:user) }

  before { https! }

  it "does not let the login page overwrite the stored forwarding url" do
    get api_keys_path
    expect(session[:forwarding_url]).to eq(api_keys_path)

    # Loading the login page must NOT clobber the stored destination.
    get login_path
    expect(session[:forwarding_url]).to eq(api_keys_path)
  end

  it "returns to the originally requested protected page, not the /lists fallback" do
    # 1. Hit a protected page while logged out -> bounced to login, url stored.
    get api_keys_path
    expect(response).to redirect_to(login_path)

    # 2. Load the login page.
    get login_path
    expect(response).to have_http_status(:ok)

    # 3. Log in -> back to /api_keys, not the lists fallback.
    post login_path, params: { user: { username: user.username, password: "password123" } }
    expect(response).to redirect_to(api_keys_path)
  end

  it "falls back to /lists when there is no prior destination" do
    post login_path, params: { user: { username: user.username, password: "password123" } }
    expect(response).to redirect_to(lists_path)
  end

  # Background fetches hit `authorize_user` exactly like a page does. Before
  # these were filtered, a PWA polling through a session expiry left its data
  # endpoint as the forwarding url, and login dropped you on raw JSON.
  describe "non-page requests" do
    it "does not store a request for a .json path" do
      get "/api_keys.json"
      expect(session[:forwarding_url]).to be_nil
    end

    it "does not store a fetch() for a JSON endpoint with no extension" do
      get "/chores/icons/signature", headers: {
        "HTTP_ACCEPT"    => "application/json",
        "Sec-Fetch-Dest" => "empty",
      }
      expect(session[:forwarding_url]).to be_nil
    end

    it "does not store a fetch() that forgot its Accept header" do
      get api_keys_path, headers: { "Sec-Fetch-Dest" => "empty" }
      expect(session[:forwarding_url]).to be_nil
    end

    it "does not store an XHR" do
      get api_keys_path, xhr: true
      expect(session[:forwarding_url]).to be_nil
    end

    it "does not store an iframe load" do
      get api_keys_path, headers: { "Sec-Fetch-Dest" => "iframe" }
      expect(session[:forwarding_url]).to be_nil
    end

    it "still stores a real browser navigation" do
      get api_keys_path, headers: {
        "HTTP_ACCEPT"    => "text/html,application/xhtml+xml",
        "Sec-Fetch-Dest" => "document",
      }
      expect(session[:forwarding_url]).to eq(api_keys_path)
    end

    it "leaves an earlier real destination intact when a fetch follows it" do
      get api_keys_path
      get "/chores/icons.json"
      expect(session[:forwarding_url]).to eq(api_keys_path)

      post login_path, params: { user: { username: user.username, password: "password123" } }
      expect(response).to redirect_to(api_keys_path)
    end
  end

  # The QR page mints a fresh single-use token every visit and the scan link
  # burns on use, so neither is a destination worth returning to.
  describe "device login pages" do
    it "does not store the scan link" do
      get device_login_claim_path("nope")
      expect(session[:forwarding_url]).to be_nil
    end

    it "does not store the QR page" do
      get device_login_path
      expect(session[:forwarding_url]).to be_nil
    end
  end
end
