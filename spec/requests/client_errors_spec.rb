require "rails_helper"

# The browser's own failures, landing in the same log as the server's.
RSpec.describe "Client errors", type: :request do
  let(:user) { User.me }
  let(:report) {
    {
      kind:    "error",
      name:    "TypeError",
      message: "Cannot read properties of undefined (reading 'items')",
      stack:   "TypeError: Cannot read properties of undefined\n    at render (application.js:120:9)",
      source:  "https://example.com/assets/application.js:120:9",
      page:    "/lists/42/items/9f3c2a1b-4d5e-4f60-8a7b-1c2d3e4f5a6b",
      url:     "https://example.com/lists/42/items/9f3c2a1b-4d5e-4f60-8a7b-1c2d3e4f5a6b?tab=1",
    }
  }

  before {
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(SlackNotifier).to receive(:puts)
  }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  it "records it by the page it happened on, with the ids taken out" do
    sign_in

    post client_errors_path, params: report, as: :json

    expect(response).to have_http_status(:no_content)
    row = ErrorReport.last
    expect(row.section).to eq("js:/lists/:id/items/:id")
    expect(row.error_class).to eq("TypeError")
    expect(row.message).to eq(report[:message])
    expect(row.backtrace).to include("application.js:120:9")
    expect(row.user_id).to eq(user.id)
    expect(row.extra).to include("kind" => "error", "url" => report[:url])
  end

  it "groups the same failure on another record's page with the first" do
    sign_in

    post client_errors_path, params: report, as: :json
    post client_errors_path, params: report.merge(page: "/lists/7/items/1"), as: :json

    expect(ErrorReport.distinct.count(:fingerprint)).to eq(1)
  end

  it "announces the first and holds back the repeats" do
    sign_in
    allow(SlackNotifier).to receive(:deliver).and_return("#portfolio")

    3.times { post client_errors_path, params: report, as: :json }

    expect(SlackNotifier).to have_received(:deliver).once
    expect(SlackNotifier).to have_received(:deliver).with(include("TypeError"), "#portfolio", any_args)
  end

  it "never announces one that has been ignored" do
    sign_in
    allow(SlackNotifier).to receive(:deliver).and_return("#portfolio")
    post client_errors_path, params: report, as: :json
    ErrorStatus.set!(ErrorReport.last.fingerprint, :ignored, user: user)

    travel_to(3.hours.from_now) { post client_errors_path, params: report, as: :json }

    expect(SlackNotifier).to have_received(:deliver).once
    expect(ErrorReport.count).to eq(2)
  end

  it "stops taking them from one person past the limit" do
    sign_in

    (ClientErrorsController::LIMIT + 3).times { |i| post client_errors_path, params: report.merge(message: "boom #{i}x"), as: :json }

    expect(ErrorReport.count).to eq(ClientErrorsController::LIMIT)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "takes nothing from somebody signed out" do
    post client_errors_path, params: report, as: :json

    expect(ErrorReport.count).to eq(0)
  end
end
