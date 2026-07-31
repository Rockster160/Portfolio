require "rails_helper"

RSpec.describe RecipesController, type: :controller do
  describe "GET #print" do
    it "redirects an anonymous request to login without creating a guest user" do
      expect {
        get :print, params: { slots: "" }
      }.not_to change(User, :count)

      expect(response).to redirect_to(login_path)
    end

    it "redirects a guest away from the print page" do
      sign_in User.create!(role: :guest)

      get :print, params: { slots: "" }

      expect(response).to redirect_to(account_path)
    end

    it "allows an authenticated (non-guest) user" do
      sign_in create(:user, role: :standard)

      get :print, params: { slots: "" }

      expect(response).to have_http_status(:ok)
    end
  end
end
