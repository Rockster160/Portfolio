require "rails_helper"

# The Teller Connect probe page. It renders a real application id into inline
# JS, so the environment selection has to be closed to whatever arrives in the
# query string rather than echoed back.
RSpec.describe SystemController, type: :controller do
  let(:me) { FactoryBot.create(:user, phone: "5550002000", role: :admin) }
  let(:standard) { FactoryBot.create(:user, phone: "5550002001") }

  before do
    allow(User).to receive(:me).and_return(me)
    me_id = me.id
    allow_any_instance_of(User).to receive(:me?) { |u| u.id == me_id }
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PORTFOLIO_TELLER_APP_ID").and_return("app_test123")
  end

  describe "GET #teller" do
    render_views

    it "is not reachable by a standard user" do
      sign_in standard
      get :teller
      expect(response).to have_http_status(:not_found)
    end

    context "when signed in as me" do
      before { sign_in me }

      it "defaults to the sandbox environment" do
        get :teller
        expect(response.body).to include(%(environment: "sandbox"))
        expect(response.body).to include(%(applicationId: "app_test123"))
      end

      it "honours a known environment" do
        get :teller, params: { env: :development }
        expect(response.body).to include(%(environment: "development"))
      end

      # The layout echoes the raw URL into an og:url meta tag on every page, so
      # the query value is present in the document regardless. What matters is
      # that it never reaches the Connect config.
      it "falls back to sandbox for an unknown environment" do
        get :teller, params: { env: "wire-me-money" }
        expect(response.body).to include(%(environment: "sandbox"))
        expect(response.body).not_to include(%(environment: "wire-me-money"))
      end

      it "says so when the app id is missing rather than rendering Connect" do
        allow(ENV).to receive(:[]).with("PORTFOLIO_TELLER_APP_ID").and_return(nil)

        get :teller
        expect(response.body).to include("PORTFOLIO_TELLER_APP_ID is not set")
        expect(response.body).not_to include("TellerConnect.setup")
      end
    end
  end
end
