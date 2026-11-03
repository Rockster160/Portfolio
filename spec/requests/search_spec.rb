require "rails_helper"

RSpec.describe "Global search", type: :request do
  let(:user) { create(:user) }
  let!(:list) { create(:list, name: "Zephyr groceries", user: user) }

  def sign_in
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  it "turns away a request that isn't signed in" do
    get search_path(q: "zephyr"), headers: { "Accept" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "answers with the grouped results" do
    sign_in
    get search_path(q: "zephyr"), headers: { "Accept" => "application/json" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["query"]).to eq("zephyr")
    lists = body["groups"].find { |g| g["group"] == "lists" }
    expect(lists["results"].first).to include(
      "group" => "lists",
      "id"    => list.id,
      "url"   => Buddy::AppPages.url_for(list_path(list)),
      "icon"  => "list",
    )
    expect(lists["results"].first.keys).to include("title", "subtitle")
  end

  it "renders the search page" do
    sign_in
    get search_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-global-search-input")
  end
end
