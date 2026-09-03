require "rails_helper"

# The "min early" setting lives on every item and defaults to 5
# (AgendaItem::DEFAULT_ARRIVE_EARLY_MINUTES). It used to be written as 0
# whenever no location was given, in Buddy and in the add form both, so that a
# location-less row wouldn't draw a leave-by band — which meant an appointment
# whose address nobody typed silently lost the setting, and adding the address
# later was a second thing to remember.
#
# Now the number is always there and the BAND is what's gated. Same rule for
# the agenda row and the details modal, from one function.
RSpec.describe "the agenda travel band (JS-side)" do
  let(:cases) { JsRunner.output("spec/javascript/agenda_travel_band_runner.js", symbolize: true)[:cases] }

  it "draws nothing for a buffer with nowhere to be" do
    expect(cases[:no_location][:visible]).to be(false)
    expect(cases[:no_location][:arriveMin]).to eq(0)
  end

  # The whole point of keeping the 5 on the row.
  it "picks the setting up the moment an address is added, with nothing re-entered" do
    expect(cases[:location_added][:arriveMin]).to eq(5)
    expect(cases[:location_added][:visible]).to be(true)
  end

  it "does not count a meeting link as somewhere to go" do
    expect(cases[:url_location][:visible]).to be(false)
  end

  # The gate is about the early buffer only. A drive is a fact on its own.
  it "leaves a measured drive alone" do
    expect(cases[:drive_no_location][:travelMin]).to eq(12)
    expect(cases[:drive_no_location][:visible]).to be(true)
  end

  it "shows both halves when there is a place and a drive" do
    expect(cases[:both]).to include(travelMin: 12, arriveMin: 10, visible: true)
  end

  it "keeps an explicit nought at nought" do
    expect(cases[:explicit_zero][:visible]).to be(false)
  end
end
