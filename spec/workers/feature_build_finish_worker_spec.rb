require "rails_helper"

RSpec.describe FeatureBuildFinishWorker do
  let(:build) { FeatureBuild.create!(user: User.me, title: "Dark mode", request: "dark mode", status: :running) }

  before { allow(described_class).to receive(:perform_in) }

  it "finishes the build once the Mini has cleaned up" do
    stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "finish", "build_id" => build.id, "merged" => true),
    ).to_return(status: 200, body: "{}")

    described_class.new.perform(build.id, true)

    expect(build.reload).to be_status_finished
    expect(described_class).not_to have_received(:perform_in)
  end

  it "asks again later while the Mini doesn't answer, and stops after a day" do
    described_class.new.perform(build.id, true, 3)
    described_class.new.perform(build.id, true, described_class::ATTEMPTS)

    expect(build.reload).not_to be_status_finished
    expect(described_class).to have_received(:perform_in).with(described_class::RETRY_IN, build.id, true, 4).once
  end
end
