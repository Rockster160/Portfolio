require "rails_helper"

RSpec.describe Users::SessionsController, type: :controller do
  describe "GET #become" do
    let(:target) { FactoryBot.create(:user) }

    it "swaps the session to the target user when the current user is an admin" do
      admin = FactoryBot.create(:user, role: :admin)
      sign_in admin

      get :become, params: { id: target.id, return_to: "/whisper" }

      expect(response).to redirect_to("/whisper")
      expect(session[:current_user_id]).to eq(target.id)
    end

    it "defaults to root_path when no return_to is given" do
      admin = FactoryBot.create(:user, role: :admin)
      sign_in admin

      get :become, params: { id: target.id }

      expect(response).to redirect_to(root_path)
      expect(session[:current_user_id]).to eq(target.id)
    end

    it "rejects non-admin users with 403" do
      user = FactoryBot.create(:user, role: :standard)
      sign_in user

      get :become, params: { id: target.id }

      expect(response).to have_http_status(:forbidden)
      expect(session[:current_user_id]).to eq(user.id)
    end

    it "rejects unauthenticated requests with 403" do
      get :become, params: { id: target.id }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
