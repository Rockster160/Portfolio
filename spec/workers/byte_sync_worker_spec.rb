require "rails_helper"

RSpec.describe ByteSyncWorker do
  it "asks the laptop, which syncs the Mini itself" do
    allow(ByteLocal).to receive(:sync).with(:laptop).and_return(true)
    allow(ByteLocal).to receive(:sync).with(:mini)

    described_class.new.perform

    expect(ByteLocal).not_to have_received(:sync).with(:mini)
  end

  it "asks the Mini directly when the laptop isn't there" do
    allow(ByteLocal).to receive(:sync).with(:laptop).and_return(false)
    allow(ByteLocal).to receive(:sync).with(:mini).and_return(true)

    described_class.new.perform

    expect(ByteLocal).to have_received(:sync).with(:mini)
  end
end
