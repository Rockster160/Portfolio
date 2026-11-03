require "rails_helper"

# A guest account is minted for somebody who ARRIVED. The endpoints a crawl
# actually hits are data endpoints, and every one of them used to get an account
# of its own - see AuthHelper#authorize_user_or_guest for the day's counts.
RSpec.describe "Guest account minting", type: :request do
  describe "a page somebody is looking at" do
    # Non-browser clients send no Sec-Fetch-Dest at all, and absence cannot
    # disqualify them - the Accept format is what carries those.
    it "mints a guest for a page navigation, with or without Sec-Fetch-Dest" do
      [{ "Sec-Fetch-Dest" => "document" }, {}].each do |headers|
        reset!
        expect { get chores_path, headers: headers }.to change(User.guest, :count).by(1)
        expect(response).to have_http_status(:ok)
      end
    end

    # The links this filter exists for. A recipe someone was sent has no account
    # behind it and never did.
    it "mints a guest for a shared recipe link" do
      recipe = Recipe.create!(user: create(:user), title: "Garlic Butter")

      expect { get recipe_path(recipe), headers: { "Sec-Fetch-Dest" => "document" } }
        .to change(User.guest, :count).by(1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "a data endpoint reached with no session" do
    # A JSON fetch with no Sec-Fetch-Dest is turned away by the format check.
    it "mints nothing for a JSON fetch, an XHR, or a service worker fetch" do
      [
        ["/chores/icons.json", { "Accept" => "application/json", "Sec-Fetch-Dest" => "empty" }],
        ["/chores/icons.json", { "Accept" => "application/json" }],
        ["/agenda_preference", { "Accept" => "application/json", "X-Requested-With" => "XMLHttpRequest" }],
        ["/agenda/sync/bootstrap", { "Accept" => "application/json", "Sec-Fetch-Dest" => "serviceworker" }],
      ].each do |path, headers|
        expect { get path, headers: headers }.not_to change(User.guest, :count)
        expect(response).to have_http_status(:unauthorized), "#{path} #{headers}"
      end
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
