require "rails_helper"

RSpec.describe TeslaCommand, ".error!" do
  before do
    DataStorage.where(name: :tesla_error).delete_all
    allow(described_class).to receive(:broadcast)
  end

  it "holds the failure and pushes it to the dashboard" do
    described_class.error!("Wakeup Error: timed out", loading: false)

    expect(DataStorage[:tesla_error]).to eq("Wakeup Error: timed out")
    expect(described_class).to have_received(:broadcast).with({ loading: false })
  end

  it "clears it once a request gets through" do
    DataStorage[:tesla_error] = "Wakeup Error: timed out"

    described_class.error!(nil)

    expect(DataStorage[:tesla_error]).to be_nil
    expect(described_class).to have_received(:broadcast).with({})
  end

  it "stays quiet when nothing had gone wrong" do
    described_class.error!(nil)

    expect(described_class).not_to have_received(:broadcast)
  end

  it "rides along on every broadcast the cell reads" do
    DataStorage[:tesla_error] = "Wakeup Error: timed out"
    allow(described_class).to receive(:broadcast).and_call_original
    allow_any_instance_of(TeslaControl).to receive(:cached_vehicle_data).and_return({ state: "online" })

    expect(described_class.format_data[:error]).to eq("Wakeup Error: timed out")
  end
end
