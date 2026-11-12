require "rails_helper"

RSpec.describe "Feature Requests page", type: :request do
  let(:user) { User.me }
  let!(:feature_request) {
    FeatureRequest.create!(user: user, title: "Repeating timers", body: "Every 30 minutes, a 10 minute break.")
  }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before do
    sign_in
    allow(FeatureBuildStartWorker).to receive(:perform_async)
  end

  it "offers a build on a request that's still wanted" do
    get system_feature_requests_path

    expect(response.body).to include("fr-btn fr-btn-build", system_feature_request_build_path(feature_request))
  end

  it "doesn't offer one on a declined request" do
    feature_request.update!(status: :declined)

    get system_feature_requests_path

    expect(response.body).not_to include("fr-btn fr-btn-build")
  end

  it "starts a build with the notes, and shows it on the row instead of the button" do
    post system_feature_request_build_path(feature_request), params: { notes: "Keep it in Jil" }

    build = feature_request.reload.latest_build
    expect(build.request).to include("Repeating timers", "Notes: Keep it in Jil")
    expect(feature_request).to be_status_planned
    expect(response).to redirect_to(system_feature_requests_path(anchor: "fr-#{feature_request.id}"))

    build.update!(status: :running, rc_url: "https://claude.ai/code/session_abc", planned_at: Time.current)
    FeatureBuilder.report_sessions!(machine: :mini, sessions: [
      { "build_id" => build.id, "kind" => "builder", "working" => true },
    ])
    get system_feature_requests_path

    expect(response.body).to include("building", "https://claude.ai/code/session_abc")
    expect(response.body).not_to include("fr-btn fr-btn-build")
  end

  it "starts a build with the images attached to the notes" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("png"), filename: "mock.png", content_type: "image/png",
    )

    post system_feature_request_build_path(feature_request), params: {
      notes:                 "Like this",
      attachment_signed_ids: [blob.signed_id],
    }

    expect(feature_request.reload.latest_build.images.map(&:blob)).to eq([blob])
  end

  it "doesn't start a second build" do
    post system_feature_request_build_path(feature_request)
    post system_feature_request_build_path(feature_request)

    expect(feature_request.feature_builds.count).to eq(1)
    expect(flash[:notice]).to include("can't be built")
  end
end
