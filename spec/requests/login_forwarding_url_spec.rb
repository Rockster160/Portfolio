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
end
