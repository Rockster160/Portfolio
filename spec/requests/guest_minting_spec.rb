require "rails_helper"

# A guest account is minted for somebody who ARRIVED. The endpoints a crawl
# actually hits are data endpoints, and every one of them used to get an account
# of its own - see AuthHelper#authorize_user_or_guest for the day's counts.
RSpec.describe "Guest account minting", type: :request do
  describe "a page somebody is looking at" do
    it "mints a guest for a page navigation" do
      expect { get chores_path, headers: { "Sec-Fetch-Dest" => "document" } }
        .to change(User.guest, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    # The links this filter exists for. A recipe someone was sent has no account
    # behind it and never did.
    it "mints a guest for a shared recipe link" do
      recipe = Recipe.create!(user: create(:user), title: "Garlic Butter")

      expect { get recipe_path(recipe), headers: { "Sec-Fetch-Dest" => "document" } }
        .to change(User.guest, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    # Non-browser clients send no Sec-Fetch-Dest at all, and absence cannot
    # disqualify them - the Accept format is what carries those.
    it "mints a guest for a page navigation that sends no Sec-Fetch-Dest" do
      expect { get chores_path }.to change(User.guest, :count).by(1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "a data endpoint reached with no session" do
    it "mints nothing for a JSON fetch" do
      expect {
        get "/chores/icons.json", headers: {
          "Accept"         => "application/json",
          "Sec-Fetch-Dest" => "empty",
        }
      }.not_to change(User.guest, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    # The format check, not Sec-Fetch-Dest, is what turns this one away.
    it "mints nothing for a JSON fetch that sends no Sec-Fetch-Dest" do
      expect {
        get "/chores/icons.json", headers: { "Accept" => "application/json" }
      }.not_to change(User.guest, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "mints nothing for an XHR" do
      expect {
        get "/agenda_preference", headers: {
          "Accept"           => "application/json",
          "X-Requested-With" => "XMLHttpRequest",
        }
      }.not_to change(User.guest, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "mints nothing for a service worker fetch" do
      expect {
        get "/agenda/sync/bootstrap", headers: {
          "Accept"         => "application/json",
          "Sec-Fetch-Dest" => "serviceworker",
        }
      }.not_to change(User.guest, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "mints nothing for a write" do
      expect { post "/agenda_items", params: { agenda_item: { name: "Dentist" } } }
        .not_to change(User.guest, :count)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # The half that must keep working: a real first visit is a page, and the
  # fetches the page fires carry the session the page was given.
  describe "the fetches a page fires afterwards" do
    it "serves a JSON fetch on the session the page navigation minted" do
      get chores_path, headers: { "Sec-Fetch-Dest" => "document" }
      expect(User.guest.count).to eq(1)

      expect {
        get "/agenda/sync/bootstrap", headers: {
          "Accept"         => "application/json",
          "Sec-Fetch-Dest" => "empty",
        }
      }.not_to change(User.guest, :count)

      expect(response).to have_http_status(:ok)
    end

    it "serves a JSON fetch for a signed-in account" do
      user = create(:user)
      post login_path, params: { user: { username: user.username, password: "password123" } }

      get "/agenda/sync/bootstrap", headers: {
        "Accept"         => "application/json",
        "Sec-Fetch-Dest" => "empty",
      }
      expect(response).to have_http_status(:ok)
    end
  end
end
