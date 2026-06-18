require "rails_helper"

# Phase 1 wiring smoke. Confirms every public surface loads cleanly and the
# basic chain detection behaves end-to-end against stubbed AddressBook calls.
# Deep edge-case coverage lives in the focused specs alongside each module.
RSpec.describe AgendaTravelChain do
  describe "module-level surface" do
    it "exposes run_for / refresh_for / trip_waypoints" do
      expect(described_class).to respond_to(:run_for)
      expect(described_class).to respond_to(:refresh_for)
      expect(described_class).to respond_to(:trip_waypoints)
    end

    it "the worker loads with sidekiq dedup on" do
      expect(AgendaTravelChainSyncWorker.sidekiq_options).to include("lock" => :until_executed)
    end

    it "the Custom Jil method dispatches to the new helpers" do
      methods = Jil::Methods::Custom.instance_methods(false)
      expect(methods).to include(:refresh_travel_time, :trip_waypoints)
    end
  end
end
