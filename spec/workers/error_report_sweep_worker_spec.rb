require "rails_helper"

RSpec.describe ErrorReportSweepWorker do
  def record(at)
    travel_to(at) { ErrorReport.record!(section: "sync", message: "timed out") }
  end

  it "sweeps rows past the retention and keeps the rest" do
    old = record((ErrorReport::RETAIN_FOR + 1.day).ago)
    recent = record(1.day.ago)

    described_class.new.perform

    expect(ErrorReport.all).to contain_exactly(recent)
    expect(ErrorReport.exists?(old.id)).to be(false)
  end

  # An ignored failure that comes back after its rows are gone is still ignored.
  it "keeps what was decided about a failure whose rows it swept" do
    old = record((ErrorReport::RETAIN_FOR + 1.day).ago)
    ErrorStatus.set!(old.fingerprint, :ignored, user: nil)

    described_class.new.perform

    expect(ErrorStatus.find_by(fingerprint: old.fingerprint)).to be_ignored
  end
end
