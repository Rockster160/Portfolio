require "rails_helper"

RSpec.describe "Page short links", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }
  let(:page) { user.pages.create!(name: "Label Maker", content: "secret steps") }

  def sign_in(as)
    as.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: as.username, password: password } }
  end

  it "gives every new page a letters-only short key" do
    expect(page.short_key).to match(/\A[A-HJ-NP-Z]{4}\z/)
  end

  it "opens the page by its short key, in any case, and offers the link to copy" do
    sign_in(user)

    get "/p/#{page.short_key.downcase}"
    expect(response).to redirect_to(page_path(page))
    follow_redirect!
    expect(response.body).to include("secret steps", %(data-url="https://#{page.short_url}"))
  end

  it "opens for someone it is shared with" do
    friend = create(:user)
    page.shared_pages.create!(user: friend)
    sign_in(friend)

    get "/p/#{page.short_key}"
    follow_redirect!
    expect(response.body).to include("secret steps")
    expect(response.body).not_to include(%(data-url="https://#{page.short_url}"))
  end

  it "keeps the page from anyone else" do
    sign_in(create(:user))

    get "/p/#{page.short_key}"
    follow_redirect!
    expect(response.body).not_to include("secret steps")
  end
end
