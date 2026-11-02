require "rails_helper"

RSpec.describe "Short links", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }

  def sign_in(as)
    as.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: as.username, password: password } }
  end

  it "shortens a link, and gives the same key back for the same link" do
    sign_in(user)

    post "/links", params: { url: "example.com/some/page?x=1" }
    link = user.short_links.last
    expect(link.url).to eq("https://example.com/some/page?x=1")
    expect(link.key).to match(/\A[A-HJ-NP-Z]{4}\z/)

    follow_redirect!
    expect(response.body).to include(%(data-url="https://rdjn.me/l/#{link.key}"))

    post "/links", params: { url: "https://example.com/some/page?x=1" }
    expect(user.short_links.count).to eq(1)
  end

  it "refuses anything that isn't a web link" do
    sign_in(user)

    ["javascript:alert(1)", "data:text/html,hi", "mailto:a@b.c", ""].each { |url|
      post "/links", params: { url: url }
    }
    expect(::ShortLink.count).to eq(0)
  end

  it "redirects anyone who opens it, in any case, and counts the visit" do
    link = user.short_links.create!(url: "https://example.com/page")

    get "/l/#{link.key.downcase}"
    expect(response).to have_http_status(:found)
    expect(response.location).to eq("https://example.com/page")
    expect(link.reload.visits).to eq(1)

    get "/l/ZZZZZ"
    expect(response).to redirect_to(login_path)
  end

  it "keeps the generator to admins" do
    sign_in(create(:user))

    get "/links"
    expect(response).to redirect_to(account_path)
    post "/links", params: { url: "https://example.com" }
    expect(::ShortLink.count).to eq(0)
  end

  it "deletes a link" do
    sign_in(user)
    link = user.short_links.create!(url: "https://example.com")

    delete "/links/#{link.id}"
    expect(::ShortLink.exists?(link.id)).to be(false)
  end
end
