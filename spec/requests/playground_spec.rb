require "rails_helper"

RSpec.describe "GET /playground", type: :request do
  # The playground is a hand-maintained wall of links to the rest of the site.
  # Nothing else exercises those route helpers, so a project that gets renamed
  # or unrouted goes unnoticed until someone clicks a dead card in public.
  it "links every project card at a path the router recognizes" do
    get "/playground"

    expect(response).to have_http_status(:ok)

    hrefs = response.body.scan(/<a href="([^"]+)" class="project-wrapper">/).flatten
    expect(hrefs).to be_present

    hrefs.each do |href|
      expect { Rails.application.routes.recognize_path(href, method: :get) }
        .not_to raise_error, "unroutable playground href: #{href}"
    end
  end
end
