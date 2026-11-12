require "rails_helper"

RSpec.describe FeatureBuildStartWorker do
  before { ActiveStorage::Current.url_options = { host: "example.com", protocol: "https" } }
  after  { ActiveStorage::Current.url_options = nil }

  let(:user)   { User.me }
  let(:thread) { user.byte_conversations.create!(mode: :buddy) }
  let(:build)  {
    allow(described_class).to receive(:perform_async)
    message = FeatureBuilder.start!(user: user, conversation: thread, text: "add dark mode")
    FeatureBuild.find(message.metadata["feature_build_id"])
  }

  it "asks the Mini to start the build, with the words to name its branch" do
    allow(FeatureBuilder::BranchName).to receive(:for).and_return("dark-mode")
    start = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including(
        "action"      => "start",
        "build_id"    => build.id,
        "request"     => "dark mode",
        "branch_name" => "dark-mode",
      ),
    ).to_return(status: 200, body: "{}")

    described_class.new.perform(build.id)

    expect(start).to have_been_requested
    expect(build.reload).to be_status_starting
  end

  it "hands the Mini a fresh link to each image the build was started with" do
    allow(FeatureBuilder::BranchName).to receive(:for).and_return("dark-mode")
    build.images.attach(io: StringIO.new("png"), filename: "mock.png", content_type: "image/png")
    start = stub_request(:post, %r{/byte/builder\z}).with { |request|
      attachments = JSON.parse(request.body)["attachments"].to_a
      attachments.length == 1 && attachments.first.values_at("filename", "content_type") == ["mock.png", "image/png"] &&
        attachments.first["url"].present?
    }.to_return(status: 200, body: "{}")

    described_class.new.perform(build.id)

    expect(start).to have_been_requested
  end

  it "says so in its message when the Mini doesn't answer" do
    allow(FeatureBuilder::BranchName).to receive(:for).and_return("dark-mode")
    described_class.new.perform(build.id)

    expect(build.reload).to be_status_failed
    expect(build.byte_message.reload.body).to include("Couldn't start", "the Mini didn't answer")
  end
end
