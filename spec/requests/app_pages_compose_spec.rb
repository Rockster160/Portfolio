require "rails_helper"

RSpec.describe "Buddy app quick prompt", type: :request do
  let(:user) { User.me }
  let!(:issued) { AppDevice.issue!(user, name: "Phone") }
  let(:headers) { { "Authorization" => "Bearer #{issued.last}" } }

  it "has nothing else to fetch, so the app can open its copy offline", :aggregate_failures do
    get app_compose_path, headers: headers

    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("textarea[name=text][autofocus]")).to be_present
    expect(page.css("link[rel=stylesheet], script[src], img")).to be_empty
  end
end
