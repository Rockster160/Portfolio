require "rails_helper"

RSpec.describe FeatureBuilderFeedbackWorker do
  let(:user)  { User.me }
  let(:build) { FeatureBuild.create!(user: user, title: "Dark mode", request: "dark mode") }

  before { allow(described_class).to receive(:perform_in) }

  def comment(text)
    travel_to(1.minute.ago) { FeatureBuilder.feedback!(build, text) }
  end

  it "types the gathered feedback into the session as one message" do
    sent = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "message", "build_id" => build.id),
    ).to_return(status: 200, body: "{}")
    comment("Rename the method")
    comment("Add a spec")

    described_class.new.perform(build.id)

    expect(sent.with { |request| request.body.include?("Rename the method") && request.body.include?("Add a spec") })
      .to have_been_requested.once
    expect(build.reload.feedback).to be_empty
  end

  it "keeps the feedback and tries again later when the Mini doesn't answer" do
    comment("Rename the method")

    described_class.new.perform(build.id)

    expect(build.reload.feedback.length).to eq(1)
    expect(described_class).to have_received(:perform_in).with(described_class::RETRY_IN, build.id)
  end
end
