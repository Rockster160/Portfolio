require "rails_helper"

RSpec.describe "Playground", type: :request do
  let(:page_headers) { { "Accept" => "text/html", "Sec-Fetch-Dest" => "document" } }

  def as(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
  end

  describe "a project you can't open" do
    it "sends a visitor with no account to its About page" do
      get "/timers", headers: page_headers
      expect(response).to redirect_to("/playground/timers")
    end

    it "sends a guest to its About page" do
      as(User.create!(role: :guest))
      get "/timers", headers: page_headers
      expect(response).to redirect_to("/playground/timers")
    end

    it "lets a registered account through" do
      as(FactoryBot.create(:user))
      get "/timers", headers: page_headers
      expect(response).not_to redirect_to("/playground/timers")
    end

    it "sends anyone but the owner from a private page to its About page" do
      as(FactoryBot.create(:user))
      get "/system/errors", headers: page_headers
      expect(response).to redirect_to("/playground/system")
    end

    it "sends a visitor on an app's own subdomain to the About page on the main site" do
      host! "byte.example.com"
      get "/", headers: page_headers
      expect(response).to redirect_to("http://example.com/playground/byte")
    end

    it "leaves a background fetch to the usual login handling" do
      get "/timers", headers: { "Accept" => "application/json" }
      expect(response.location.to_s).not_to include("/playground")
    end

    it "leaves an unlisted project's gate alone" do
      get "/emails", headers: page_headers
      expect(response).to redirect_to(login_path)
    end
  end

  describe "the About page" do
    it "locks Open with the reason for a visitor with no account" do
      get "/playground/timers", headers: page_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("You must have an account to use this tool", "Sign in")
    end

    it "offers Open to someone who can use it" do
      as(FactoryBot.create(:user))
      get "/playground/timers", headers: page_headers
      expect(response.body).to include("Open Timers")
    end

    it "offers no Open at all for a project with no page" do
      get "/playground/jarvis", headers: page_headers
      expect(response.body).not_to include("Open Jarvis", "🔒")
    end

    it "is a 404 for a project that isn't listed" do
      get "/playground/emails", headers: page_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the Playground" do
    # Nothing else exercises the cards' route helpers, so a project that gets
    # renamed or unrouted would otherwise go unnoticed until someone clicks a
    # dead card in public.
    it "links every project it opens at a path the router recognizes" do
      as(FactoryBot.create(:user))
      get "/playground", headers: page_headers

      hrefs = response.body.scan(/<a class="project-action is-open is-primary" href="([^"]+)">/).flatten
      expect(hrefs).to be_present
      hrefs.each do |href|
        expect { Rails.application.routes.recognize_path(href, method: :get) }.not_to(
          raise_error, "unroutable playground href: #{href}"
        )
      end
    end

    it "lists every project with an About link, and locks what the visitor can't open" do
      get "/playground", headers: page_headers
      expect(response).to have_http_status(:ok)
      PlaygroundProject.listed.each do |project|
        expect(response.body).to include("/playground/#{project.slug}")
      end
      expect(response.body).to include("🔒 Open", 'data-tooltip="You must have an account to use this tool"')
      PlaygroundProject.listed.select(&:api).each do |project|
        expect(response.body).to include(%(data-modal="#code-example-#{project.api}"), %(id="code-example-#{project.api}"))
      end
    end
  end
end
