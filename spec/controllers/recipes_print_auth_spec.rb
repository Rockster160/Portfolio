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

    describe "page slots" do
      render_views

      let(:user) { create(:user, role: :standard) }

      before { sign_in user }

      it "renders an owned page through the markdown, table included" do
        page = user.pages.create!(name: "Brine", content: "| Salt | Water |\n|---|---|\n| 1 tbsp | 1 cup |")

        get :print, params: { slots: "p#{page.id},,," }

        expect(response.body).to include("Brine")
        expect(response.body).to match(%r{<th>Salt</th>})
      end

      it "will not render someone else's page" do
        other = create(:user).pages.create!(name: "Secret", content: "nope")

        get :print, params: { slots: "p#{other.id},,," }

        expect(response.body).not_to include("Secret")
      end

      it "lists pages in the picker" do
        user.pages.create!(name: "Brine", content: "x")

        get :print, params: { slots: "" }

        expect(response.body).to include("Brine")
      end
    end
  end
end
