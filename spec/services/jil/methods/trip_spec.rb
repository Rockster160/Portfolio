require "rails_helper"

# Thin Jil wrapper over TripState. The wrapper is just a delegation
# surface; TripState's own spec covers the behavior. This spec asserts
# the delegation pattern + the AgendaItem id resolution for `start`.
RSpec.describe Jil::Methods::Trip do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }
  let(:item) {
    agenda.agenda_items.create!(
      kind: :event, name: "TMS",
      start_at: 1.day.from_now, end_at: 1.day.from_now + 30.minutes,
      location: "Office",
      metadata: {
        "travel" => {
          "before_legs" => [
            { "from" => "Home",   "to" => "Costco", "drive_seconds" => 600, "dwell_seconds" => 300 },
            { "from" => "Costco", "to" => "Office", "drive_seconds" => 600, "dwell_seconds" => 0   },
          ],
        },
      },
    )
  }
  let(:jil) { ::Jil::Executor.new(user, "") }
  let(:trip) { described_class.new(jil) }

  before do
    allow(::AgendaTravelChainSyncWorker).to receive(:perform_async).and_return(nil)
    allow(::Jil).to receive(:trigger)
  end

  it "starts at leg 0 from an item, its id as a string, or a Hash carrying the id" do
    expect(trip.start(item)).to be(true)
    expect(::TripState.current(user)[:leg_index]).to eq(0)

    [item.id.to_s, { "id" => item.id }].each { |ref|
      expect(trip.start(ref)).to be(true), ref.inspect
      expect(::TripState.current(user)[:agenda_item_id]).to eq(item.id)
    }

    expect(trip.start(999_999)).to be(false)
  end

  it "walks the stops through advance, and finish clears the trip" do
    trip.start(item)
    expect(trip.active?).to be(true)
    expect(trip.current_stop).to eq("Costco")
    expect(trip.next_stop).to eq("Office")

    trip.advance
    expect(trip.current_stop).to eq("Office")

    trip.finish
    expect(trip.active?).to be(false)
    expect(trip.current_stop).to eq("")
  end

  it "arrived? proxies to TripState.arrived_at_current_stop?" do
    trip.start(item)
    allow(::TripState).to receive(:arrived_at_current_stop?).with(user).and_return(true)
    expect(trip.arrived?).to be(true)
  end
end
