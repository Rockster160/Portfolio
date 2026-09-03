require "rails_helper"

RSpec.describe "System page", type: :request do
  # /system is behind MeConstraint, so it only ever loads for the owner.
  let(:user) { User.me }

  before { post login_path, params: { user: { username: user.username, password: "password" } } }

  it "links the interview tracker" do
    get system_path

    expect(response).to have_http_status(:ok)

    hrefs = response.body.scan(/<a class="system-card[^"]*" href="([^"]+)">/).flatten
    expect(hrefs).to include(interviews_path)
    expect(response.body).to include("Interview Tracker")
  end

  # The blip counts the chases owed; the number itself is JobNote's business
  # and is covered there. What matters here is that the page can work it out
  # and render it.
  it "renders with follow-ups outstanding" do
    job = JobApplication.create!(user: user, company: "Acme")
    job.notes.create!(body: "Chase", follow_up_at: 2.days.ago)

    get system_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("system-card-blip")
  end
end
