require "rails_helper"

RSpec.describe FeatureBuildStartWorker do
  before {
    ActiveStorage::Current.url_options = { host: "example.com", protocol: "https" }
    allow(FeatureBuilder::Repos).to receive(:for).and_return(FeatureBuilder::Repos::PORTFOLIO)
  }

  after { ActiveStorage::Current.url_options = nil }

  let(:user)   { User.me }
  let(:thread) { user.byte_conversations.create!(mode: :buddy) }
  let(:build)  {
    allow(described_class).to receive(:perform_async)
    message = FeatureBuilder.start!(user: user, conversation: thread, text: "add dark mode")
    FeatureBuild.find(message.metadata["feature_build_id"])
  }

  it "asks the Mini to start the build, with the words to name its branch and how to talk" do
    allow(FeatureBuilder::BranchName).to receive(:for).and_return("dark-mode")
    start = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including(
        "action"      => "start",
        "build_id"    => build.id,
        "request"     => "dark mode\n\n#{FeatureBuilder::TEXTING}",
        "branch_name" => "dark-mode",
        "kind"        => "feature",
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

  describe "naming the build" do
    before { allow(FeatureBuilder::BranchName).to receive(:for).and_return("dark-mode") }

    it "names it before the Mini is told, and shows the name in its message" do
      allow(FeatureBuilder::Title).to receive(:for).with("dark mode", user: user).and_return("Dark mode")
      start = stub_request(:post, %r{/byte/builder\z}).with(
        body: hash_including("action" => "start", "title" => "Dark mode"),
      ).to_return(status: 200, body: "{}")

      described_class.new.perform(build.id, "dark mode")

      expect(start).to have_been_requested
      expect(build.reload.title).to eq("Dark mode")
      expect(build.byte_message.reload.body).to include("**Dark mode**")
    end

    it "puts an audit's name under its prefix" do
      allow(FeatureBuilder::Title).to receive(:for).and_return("Reminders firing twice")
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 200, body: "{}")
      build.update!(kind: :audit)

      described_class.new.perform(build.id, "reminders keep firing twice")

      expect(build.reload.title).to eq("Audit: Reminders firing twice")
    end

    it "keeps the request's first line when the model gives nothing" do
      allow(FeatureBuilder::Title).to receive(:for).and_return(nil)
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 200, body: "{}")

      described_class.new.perform(build.id, "dark mode")

      expect(build.reload.title).to eq("dark mode")
    end

    it "leaves a chosen name alone" do
      allow(FeatureBuilder::Title).to receive(:for)
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 200, body: "{}")

      described_class.new.perform(build.id)

      expect(FeatureBuilder::Title).not_to have_received(:for)
    end
  end

  describe "the repo it builds in" do
    let(:hass) { "Rockster160/hass-config" }

    before { allow(FeatureBuilder::BranchName).to receive(:for).and_return("porch-light") }

    it "tells the Mini the repo the request is for" do
      allow(FeatureBuilder::Repos).to receive(:for).with("dark mode", user: user).and_return(hass)
      start = stub_request(:post, %r{/byte/builder\z}).with(
        body: hash_including("action" => "start", "repo" => hass),
      ).to_return(status: 200, body: "{}")

      described_class.new.perform(build.id)

      expect(start).to have_been_requested
      expect(build.reload.repo).to eq(hass)
    end

    it "works where the build it carries on from did, without asking the model" do
      parent = FeatureBuild.create!(user: user, title: "Porch", request: "porch", repo: hass)
      build.update!(parent: parent)
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 200, body: "{}")

      described_class.new.perform(build.id)

      expect(build.reload.repo).to eq(hass)
      expect(FeatureBuilder::Repos).not_to have_received(:for)
    end

    it "keeps an audit in Portfolio" do
      build.update!(kind: :audit)
      stub_request(:post, %r{/byte/builder\z}).to_return(status: 200, body: "{}")

      described_class.new.perform(build.id)

      expect(build.reload.repo).to eq(FeatureBuilder::Repos::PORTFOLIO)
      expect(FeatureBuilder::Repos).not_to have_received(:for)
    end
  end
end
