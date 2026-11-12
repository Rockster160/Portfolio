require "rails_helper"

RSpec.describe FeatureBuildSyncWorker do
  before { allow(described_class).to receive(:perform_in) }

  it "tells the Mini master moved" do
    sync = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "sync"),
    ).to_return(status: 200, body: "{}")

    described_class.new.perform

    expect(sync).to have_been_requested
    expect(described_class).not_to have_received(:perform_in)
  end

  it "tries a few more times while the Mini doesn't answer, then leaves it to the Mini" do
    stub_request(:post, %r{/byte/builder\z}).to_return(status: 502)

    described_class.new.perform(2)
    described_class.new.perform(described_class::ATTEMPTS)

    expect(described_class).to have_received(:perform_in).with(described_class::RETRY_IN, 3).once
  end
end
