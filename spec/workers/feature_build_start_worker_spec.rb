require "rails_helper"

RSpec.describe FeatureBuildStartWorker do
  let(:user)   { User.me }
  let(:thread) { user.byte_conversations.create!(mode: :buddy) }
  let(:build)  {
    allow(described_class).to receive(:perform_async)
    message = FeatureBuilder.start!(user: user, conversation: thread, text: "add dark mode")
    FeatureBuild.find(message.metadata["feature_build_id"])
  }

  it "asks the Mini to start the build" do
    start = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "start", "build_id" => build.id, "request" => "dark mode"),
    ).to_return(status: 200, body: "{}")

    described_class.new.perform(build.id)

    expect(start).to have_been_requested
    expect(build.reload).to be_status_starting
  end

  it "says so in its message when the Mini doesn't answer" do
    described_class.new.perform(build.id)

    expect(build.reload).to be_status_failed
    expect(build.byte_message.reload.body).to include("Couldn't start", "the Mini didn't answer")
  end
end
